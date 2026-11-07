import Foundation
import System
import XCTest
@testable import tart

// Avoid Tart's Darwin type shadowing the system function
private let connectTestSocket = connect

final class SoftnetControlSocketTests: XCTestCase {
  func testRelaysEachRequestLineAndItsResponse() throws {
    try withControlSocket { socketURL in
      let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
      XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

      let client = try connect(socketURL)
      defer { close(client) }

      XCTAssertEqual(try exchange(client, "{\"id\":1}\n"), "reply {\"id\":1}\n")
      XCTAssertEqual(try exchange(client, "{\"id\":2}\n"), "reply {\"id\":2}\n")
    }
  }

  func testPartialRequestFromDisconnectedClientIsNotRelayed() throws {
    try withControlSocket { socketURL in
      let abandoned = try connect(socketURL)
      try send(abandoned, "{\"id\":\"partial")
      close(abandoned)

      let client = try connect(socketURL)
      defer { close(client) }

      XCTAssertEqual(try exchange(client, "{\"id\":3}\n"), "reply {\"id\":3}\n")
    }
  }

  func testClientsThatComeWhileAnotherIsServedWaitTheirTurn() throws {
    try withControlSocket { socketURL in
      let first = try connect(socketURL)
      XCTAssertEqual(try exchange(first, "{\"id\":6}\n"), "reply {\"id\":6}\n")

      // Served one at a time: these wait while the first is still connected
      let waiting = try (0..<3).map { _ in try connect(socketURL) }
      close(first)

      for (i, client) in waiting.enumerated() {
        XCTAssertEqual(try exchange(client, "{\"id\":\(7 + i)}\n"), "reply {\"id\":\(7 + i)}\n")
        close(client)
      }
    }
  }

  func testResponseForDisconnectedClientIsNotSeenByTheNext() throws {
    try withControlSocket { socketURL in
      let abandoned = try connect(socketURL)
      try send(abandoned, "{\"id\":4}\n")
      close(abandoned)

      let client = try connect(socketURL)
      defer { close(client) }

      XCTAssertEqual(try exchange(client, "{\"id\":5}\n"), "reply {\"id\":5}\n")
    }
  }

  func testOversizedRequestSentInChunksIsAnsweredAndItsClientClosed() throws {
    try withControlSocket { socketURL in
      let client = try connect(socketURL)
      defer { close(client) }

      // Exactly one byte past the limit with no newline, then nothing more: the
      // answer must not wait for a newline that a stalled client never sends
      let chunk = String(repeating: "x", count: 64 * 1024)
      for _ in 0..<(SoftnetControlSocket.maxLineBytes / chunk.utf8.count) {
        try send(client, chunk)
      }
      try send(client, String(repeating: "x", count: SoftnetControlSocket.maxLineBytes % chunk.utf8.count))

      XCTAssertEqual(try readLine(client), oversizedRequestResponse)
      guard isClosed(client) else {
        return XCTFail("the relay kept reading a client past the limit")
      }

      // Nobody is left waiting behind it
      let next = try connect(socketURL)
      defer { close(next) }
      XCTAssertEqual(try exchange(next, "{\"id\":10}\n"), "reply {\"id\":10}\n")
    }
  }

  func testOversizedRequestWhoseNewlineCrossesTheLimitIsNotRelayed() throws {
    try withControlSocket { socketURL in
      let client = try connect(socketURL)
      defer { close(client) }

      // Up to the limit, then the byte past it and the newline in one write, so the
      // newline arrives in the read that crosses the limit
      try send(client, String(repeating: "x", count: SoftnetControlSocket.maxLineBytes - 1))
      try send(client, "x\n")

      XCTAssertEqual(try readLine(client), oversizedRequestResponse)
      guard isClosed(client) else {
        return XCTFail("the relay kept reading a client past the limit")
      }

      let next = try connect(socketURL)
      defer { close(next) }
      XCTAssertEqual(try exchange(next, "{\"id\":11}\n"), "reply {\"id\":11}\n")
    }
  }

  func testOversizedRequestResponseIsSoftnetsParseError() throws {
    let response = try XCTUnwrap(
      JSONSerialization.jsonObject(with: SoftnetControlSocket.oversizedRequestResponse) as? [String: Any]
    )
    let error = try XCTUnwrap(response["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? Int, -32700)
    XCTAssertEqual(error["message"] as? String, "request exceeds the maximum frame size")
    XCTAssertTrue(response["id"] is NSNull)
    XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
    XCTAssertEqual(SoftnetControlSocket.oversizedRequestResponse.last, UInt8(ascii: "\n"))
  }

  func testAcceptFailureRemovesTheSocketAndIsReported() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    let originalDirectory = FileManager.default.currentDirectoryPath
    defer {
      FileManager.default.changeCurrentDirectoryPath(originalDirectory)
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    var fds: [Int32] = [-1, -1]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    defer {
      close(fds[0])
      close(fds[1])
    }

    let socketURL = URL(fileURLWithPath: "softnet.sock", relativeTo: temporaryDirectory)
    let reported = DispatchSemaphore(value: 0)
    var reportedError: Error?
    let controlSocket = try SoftnetControlSocket(socketURL, softnetFD: fds[1], acceptClient: { _ in
      errno = EBADF
      return -1
    }, onError: { error in
      reportedError = error
      reported.signal()
    })
    XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))

    controlSocket.serve()

    // Bounds the wait only if the failure is never reported
    XCTAssertEqual(reported.wait(timeout: .now() + 10), .success)
    XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    XCTAssertTrue(String(describing: try XCTUnwrap(reportedError)).contains("\(Errno.badFileDescriptor)"))
  }

  private var oversizedRequestResponse: String {
    String(decoding: SoftnetControlSocket.oversizedRequestResponse, as: UTF8.self)
  }

  // Starts a control socket in a temporary directory with a stand-in for Softnet
  // that answers every request line with "reply " and the line
  private func withControlSocket(_ body: (URL) throws -> Void) throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    let originalDirectory = FileManager.default.currentDirectoryPath
    defer {
      FileManager.default.changeCurrentDirectoryPath(originalDirectory)
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let socketURL = URL(fileURLWithPath: "softnet.sock", relativeTo: temporaryDirectory)
    let softnetFD = try SoftnetControlSocket.start(socketURL)

    let softnetFinished = DispatchSemaphore(value: 0)
    let softnet = Thread {
      defer { softnetFinished.signal() }
      var pending = [UInt8]()
      var chunk = [UInt8](repeating: 0, count: 4096)

      while true {
        let count = read(softnetFD, &chunk, chunk.count)
        if count <= 0 {
          return
        }
        pending += chunk[0..<count]

        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
          let reply = Array("reply ".utf8) + pending[...newline]
          pending.removeSubrange(...newline)
          _ = write(softnetFD, reply, reply.count)
        }
      }
    }
    softnet.start()
    defer {
      shutdown(softnetFD, SHUT_RDWR)
      softnetFinished.wait()
      close(softnetFD)
    }

    try body(URL(fileURLWithPath: socketURL.absoluteURL.path))
  }

  private func connect(_ socketURL: URL) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketURL.path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: path)
      buffer[path.count] = 0
    }

    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connectTestSocket(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: errno)!)
    }

    var enabled: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))

    return fd
  }

  private func send(_ fd: Int32, _ text: String) throws {
    let bytes = Array(text.utf8)
    guard write(fd, bytes, bytes.count) == bytes.count else {
      throw POSIXError(POSIXErrorCode(rawValue: errno)!)
    }
  }

  private func exchange(_ fd: Int32, _ request: String) throws -> String {
    try send(fd, request)

    return try readLine(fd)
  }

  private func readLine(_ fd: Int32) throws -> String {
    var response = [UInt8]()
    var byte: UInt8 = 0
    while read(fd, &byte, 1) == 1 {
      response.append(byte)
      if byte == UInt8(ascii: "\n") {
        break
      }
    }

    return String(decoding: response, as: UTF8.self)
  }

  // Whether the relay has closed the connection, with nothing more to read
  private func isClosed(_ fd: Int32) -> Bool {
    // Bounds the wait only if the relay keeps the connection open
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var byte: UInt8 = 0
    return read(fd, &byte, 1) == 0
  }
}
