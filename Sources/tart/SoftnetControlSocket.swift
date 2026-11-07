import Foundation
import Darwin
import System

// Avoid Tart's Darwin type shadowing the system functions
private let systemBind = bind
private let systemWrite = write

/// Serves Softnet's control channel on a Unix socket in the VM's directory.
///
/// Softnet answers each request line with exactly one response line, so clients are served one
/// at a time and only complete lines are relayed. A client that disconnects mid-request therefore
/// cannot leave a partial request or an unread response for the next one.
class SoftnetControlSocket {
  // Softnet's request limit plus the newline
  static let maxLineBytes = 1024 * 1024 + 1

  // Clients waiting while another is served. A queue of one refused a client
  // that came while one that had already gone was still waiting to be accepted.
  static let backlog: Int32 = 16

  // What Softnet answers a request longer than its limit with
  static let oversizedRequestResponse = Data(
    "{\"error\":{\"code\":-32700,\"message\":\"request exceeds the maximum frame size\"},\"id\":null,\"jsonrpc\":\"2.0\"}\n".utf8
  )

  let socketURL: URL
  private let listenFD: Int32
  private let softnetFD: Int32
  private let acceptClient: (Int32) -> Int32
  private let onError: (Error) -> Void

  /// Starts serving and returns the descriptor to pass to Softnet as its control channel.
  static func start(_ socketURL: URL) throws -> Int32 {
    var fds: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
      throw SoftnetError.InitializationFailed(why: "socketpair() failed: \(Errno(rawValue: errno))")
    }

    do {
      // Keep the relay's end out of Softnet, so its exit is seen as end of file
      guard fcntl(fds[1], F_SETFD, FD_CLOEXEC) == 0 else {
        throw SoftnetError.InitializationFailed(why: "fcntl() failed: \(Errno(rawValue: errno))")
      }

      let controlSocket = try SoftnetControlSocket(socketURL, softnetFD: fds[1])
      controlSocket.serve()
    } catch {
      close(fds[0])
      close(fds[1])
      throw error
    }

    return fds[0]
  }

  init(
    _ socketURL: URL,
    softnetFD: Int32,
    acceptClient: @escaping (Int32) -> Int32 = { accept($0, nil, nil) },
    onError: @escaping (Error) -> Void = { fputs("Failed to run Softnet control socket: \($0)\n", stderr) }
  ) throws {
    self.socketURL = socketURL
    self.softnetFD = softnetFD
    self.acceptClient = acceptClient
    self.onError = onError
    try Self.disableSIGPIPE(softnetFD)

    // Remove the socket file from previous "tart run" invocations, if any,
    // otherwise we may get the "address already in use" error
    try? FileManager.default.removeItem(at: socketURL)

    // Bind relative to the VM's base directory to work around the Unix domain
    // socket 104 byte limitation, as ControlSocket does
    if let baseURL = socketURL.baseURL {
      FileManager.default.changeCurrentDirectoryPath(baseURL.absoluteURL.path(percentEncoded: false))
    }

    listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listenFD >= 0, fcntl(listenFD, F_SETFD, FD_CLOEXEC) == 0 else {
      throw SoftnetError.InitializationFailed(why: "socket() failed: \(Errno(rawValue: errno))")
    }

    do {
      // Accepted connections inherit this, so a client that has already gone can't raise SIGPIPE
      try Self.disableSIGPIPE(listenFD)
      try Self.bindSocket(listenFD, path: socketURL.relativePath)

      // Restrict who can connect before accepting any connections
      guard chmod(socketURL.relativePath, 0o600) == 0, listen(listenFD, Self.backlog) == 0 else {
        throw SoftnetError.InitializationFailed(why: "failed to listen on \(socketURL.relativePath): \(Errno(rawValue: errno))")
      }
    } catch {
      close(listenFD)
      throw error
    }
  }

  func serve() {
    let thread = Thread {
      if let error = self.serveClients() {
        self.onError(error)
      }
    }
    thread.name = "softnet-control-socket"
    thread.start()
  }

  /// Serves clients until Softnet goes away or accepting fails, which is returned.
  /// Either way the socket is closed and removed, so it is never left behind unserved.
  private func serveClients() -> Error? {
    defer {
      close(listenFD)
      try? FileManager.default.removeItem(at: socketURL)
    }

    let softnet = LineReader(softnetFD)

    while true {
      let clientFD = acceptClient(listenFD)
      if clientFD < 0 {
        let error = errno
        if error == EINTR || error == ECONNABORTED {
          continue
        }

        return SoftnetError.RuntimeFailed(why: "accept() failed on \(socketURL.relativePath): \(Errno(rawValue: error))")
      }

      let softnetAlive = relay(clientFD, softnet)
      close(clientFD)

      if !softnetAlive {
        return nil
      }
    }
  }

  /// Relays the client's requests until it disconnects. Returns false once Softnet has gone away.
  private func relay(_ clientFD: Int32, _ softnet: LineReader) -> Bool {
    // Writing to a client without this could raise SIGPIPE, and it fails when the client has already gone
    guard (try? Self.disableSIGPIPE(clientFD)) != nil else {
      return true
    }

    let client = LineReader(clientFD)

    while true {
      let request: Data
      switch client.next() {
      case .line(let line):
        request = line
      case .tooLong:
        // Answered as Softnet would, without passing it on. The client is then closed
        // rather than read to its newline, which might never come while other clients wait.
        _ = Self.writeAll(clientFD, Self.oversizedRequestResponse)
        return true
      case .end:
        return true
      }

      guard Self.writeAll(softnetFD, request) else {
        return false
      }

      guard case .line(let response) = softnet.next() else {
        return false
      }

      // The response is read even if the client has gone, so the next client starts in sync
      guard Self.writeAll(clientFD, response) else {
        return true
      }
    }
  }

  private static func bindSocket(_ fd: Int32, path: String) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)

    let pathBytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count < capacity else {
      throw SoftnetError.InitializationFailed(why: "socket path \(path) is too long")
    }

    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: pathBytes)
      buffer[pathBytes.count] = 0
    }

    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        systemBind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      throw SoftnetError.InitializationFailed(why: "failed to bind \(path): \(Errno(rawValue: errno))")
    }
  }

  private static func disableSIGPIPE(_ fd: Int32) throws {
    var enabled: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
      throw SoftnetError.InitializationFailed(why: "setsockopt(SO_NOSIGPIPE) failed: \(Errno(rawValue: errno))")
    }
  }

  private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { buffer in
      var offset = 0

      while offset < buffer.count {
        let written = systemWrite(fd, buffer.baseAddress! + offset, buffer.count - offset)
        if written < 0 {
          if errno == EINTR {
            continue
          }

          return false
        }

        offset += written
      }

      return true
    }
  }
}

/// Reads newline-terminated lines from a descriptor.
private class LineReader {
  enum Result {
    /// A line including its newline
    case line(Data)
    /// A line longer than SoftnetControlSocket.maxLineBytes, after which the descriptor
    /// is not read any further
    case tooLong
    /// End of file or an error
    case end
  }

  private let fd: Int32
  private var buffer = Data()

  init(_ fd: Int32) {
    self.fd = fd
  }

  func next() -> Result {
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)

    while true {
      if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
        // Its newline came in the read that took it past the limit
        if newline - buffer.startIndex + 1 > SoftnetControlSocket.maxLineBytes {
          return .tooLong
        }

        let line = buffer[buffer.startIndex...newline]
        buffer = Data(buffer[buffer.index(after: newline)...])

        return .line(Data(line))
      }

      // Reported now rather than at the newline, which may never come
      if buffer.count >= SoftnetControlSocket.maxLineBytes {
        return .tooLong
      }

      let count = read(fd, &chunk, chunk.count)
      if count < 0 && errno == EINTR {
        continue
      }
      if count <= 0 {
        return .end
      }

      buffer.append(contentsOf: chunk[0..<count])
    }
  }
}
