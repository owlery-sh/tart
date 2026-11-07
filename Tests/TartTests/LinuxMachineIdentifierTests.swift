import Foundation
import Virtualization
import XCTest
@testable import tart

final class LinuxMachineIdentifierTests: XCTestCase {
  func testFirstRunKeepsANewIdentifierAndLaterRunsReadIt() throws {
    let vmDir = try temporaryVMDirectory()

    let first = try Linux.machineIdentifier(nvramURL: vmDir.nvramURL)
    let again = try Linux.machineIdentifier(nvramURL: vmDir.nvramURL)

    XCTAssertEqual(first.dataRepresentation, again.dataRepresentation)
    XCTAssertEqual(try Data(contentsOf: vmDir.machineIdentifierURL), first.dataRepresentation)
  }

  func testAnUnreadableIdentifierIsAnErrorAndIsLeftAlone() throws {
    let vmDir = try temporaryVMDirectory()
    let garbage = Data("not an identifier".utf8)
    try garbage.write(to: vmDir.machineIdentifierURL)

    XCTAssertThrowsError(try Linux.machineIdentifier(nvramURL: vmDir.nvramURL))
    XCTAssertEqual(try Data(contentsOf: vmDir.machineIdentifierURL), garbage)
  }

  func testAnOversizedIdentifierIsNotRead() throws {
    let vmDir = try temporaryVMDirectory()
    let big = Data(count: Linux.machineIdentifierMaxSize + 1)
    try big.write(to: vmDir.machineIdentifierURL)

    XCTAssertThrowsError(try Linux.machineIdentifier(nvramURL: vmDir.nvramURL))
    XCTAssertEqual(try Data(contentsOf: vmDir.machineIdentifierURL), big)
  }

  func testAnIdentifierThatIsNotAFileIsNotRead() throws {
    let vmDir = try temporaryVMDirectory()
    try FileManager.default.createDirectory(at: vmDir.machineIdentifierURL, withIntermediateDirectories: false)

    XCTAssertThrowsError(try Linux.machineIdentifier(nvramURL: vmDir.nvramURL))
  }

  func testASavedStateWithoutAnIdentifierIsAnError() throws {
    let vmDir = try temporaryVMDirectory()
    try touch(vmDir.stateURL)

    XCTAssertThrowsError(try Linux.machineIdentifier(nvramURL: vmDir.nvramURL))
    XCTAssertFalse(FileManager.default.fileExists(atPath: vmDir.machineIdentifierURL.path))
  }

  func testInitializeRemovesTheIdentifier() throws {
    let vmDir = try temporaryVMDirectory()
    _ = try Linux.machineIdentifier(nvramURL: vmDir.nvramURL)

    try vmDir.initialize(overwrite: true)

    XCTAssertFalse(FileManager.default.fileExists(atPath: vmDir.machineIdentifierURL.path))
  }

  func testACloneOfASavedLinuxVMTakesItsIdentifier() throws {
    let source = try linuxVM()
    let id = try Linux.machineIdentifier(nvramURL: source.nvramURL)
    try touch(source.stateURL)
    let clone = try temporaryVMDirectory()

    try source.clone(to: clone, generateMAC: false)

    XCTAssertTrue(FileManager.default.fileExists(atPath: clone.stateURL.path))
    XCTAssertEqual(try Data(contentsOf: clone.machineIdentifierURL), id.dataRepresentation)
  }

  func testACloneOfASavedLinuxVMWithoutAnIdentifierFailsAndKeepsNoState() throws {
    let source = try linuxVM()
    try touch(source.stateURL)
    let clone = try temporaryVMDirectory()

    XCTAssertThrowsError(try source.clone(to: clone, generateMAC: false))

    XCTAssertFalse(FileManager.default.fileExists(atPath: clone.stateURL.path))
  }

  func testACloneOfALinuxVMWithNoStateMakesItsOwnIdentifier() throws {
    let source = try linuxVM()
    _ = try Linux.machineIdentifier(nvramURL: source.nvramURL)
    let clone = try temporaryVMDirectory()

    try source.clone(to: clone, generateMAC: false)

    XCTAssertFalse(FileManager.default.fileExists(atPath: clone.machineIdentifierURL.path))
  }

  func testAnImportOfASavedLinuxVMTakesItsIdentifier() throws {
    let source = try linuxVM()
    let id = try Linux.machineIdentifier(nvramURL: source.nvramURL)
    try touch(source.stateURL)
    let imported = try temporaryVMDirectory()

    try imported.importFromArchive(path: try exported(source).path)

    XCTAssertTrue(FileManager.default.fileExists(atPath: imported.stateURL.path))
    XCTAssertEqual(try Data(contentsOf: imported.machineIdentifierURL), id.dataRepresentation)
  }

  func testAnImportOfALinuxVMWithNoStateMakesItsOwnIdentifier() throws {
    let source = try linuxVM()
    _ = try Linux.machineIdentifier(nvramURL: source.nvramURL)
    let archive = try exported(source)
    let first = try temporaryVMDirectory()
    let second = try temporaryVMDirectory()

    try first.importFromArchive(path: archive.path)
    try second.importFromArchive(path: archive.path)

    XCTAssertFalse(FileManager.default.fileExists(atPath: first.machineIdentifierURL.path))
    XCTAssertNotEqual(
      try Linux.machineIdentifier(nvramURL: first.nvramURL).dataRepresentation,
      try Linux.machineIdentifier(nvramURL: second.nvramURL).dataRepresentation
    )
  }

  func testAnImportThatLosesItsStateLosesTheIdentifierToo() throws {
    let source = try linuxVM()
    _ = try Linux.machineIdentifier(nvramURL: source.nvramURL)
    try touch(source.stateURL)
    let imported = try temporaryVMDirectory()
    try imported.importFromArchive(path: try exported(source).path)

    // What import does on a MAC address collision.
    try imported.regenerateMACAddress()

    XCTAssertFalse(FileManager.default.fileExists(atPath: imported.stateURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: imported.machineIdentifierURL.path))
  }

  func testACloneOfASavedLinuxVMWithANewMACLosesStateAndIdentifier() throws {
    let source = try linuxVM()
    let id = try Linux.machineIdentifier(nvramURL: source.nvramURL)
    try touch(source.stateURL)
    let clone = try temporaryVMDirectory()

    try source.clone(to: clone, generateMAC: true)

    XCTAssertFalse(FileManager.default.fileExists(atPath: clone.stateURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: clone.machineIdentifierURL.path))
    XCTAssertNotEqual(try Linux.machineIdentifier(nvramURL: clone.nvramURL).dataRepresentation, id.dataRepresentation)
  }

  // What run does to a VM whose MAC address collides with a running one's.
  func testANewMACForASavedLinuxVMLosesStateAndIdentifier() throws {
    let vmDir = try linuxVM()
    let id = try Linux.machineIdentifier(nvramURL: vmDir.nvramURL)
    try touch(vmDir.stateURL)

    try vmDir.regenerateMACAddress()

    XCTAssertFalse(FileManager.default.fileExists(atPath: vmDir.stateURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: vmDir.machineIdentifierURL.path))
    XCTAssertNotEqual(try Linux.machineIdentifier(nvramURL: vmDir.nvramURL).dataRepresentation, id.dataRepresentation)
  }

  func testANewMACThatCannotBeSavedKeepsStateAndIdentifier() throws {
    let vmDir = try linuxVM()
    let id = try Linux.machineIdentifier(nvramURL: vmDir.nvramURL)
    try touch(vmDir.stateURL)
    let mac = try vmDir.macAddress()
    try readOnly(vmDir.configURL)

    XCTAssertThrowsError(try vmDir.regenerateMACAddress())

    XCTAssertEqual(try vmDir.macAddress(), mac)
    XCTAssertTrue(FileManager.default.fileExists(atPath: vmDir.stateURL.path))
    XCTAssertEqual(try Data(contentsOf: vmDir.machineIdentifierURL), id.dataRepresentation)
  }

  func testAnIdentifierThatCannotBeRemovedFailsTheImport() throws {
    let source = try linuxVM()
    try undeletable(source.machineIdentifierURL)
    let imported = try temporaryVMDirectory()
    let archive = try exported(source)
    addTeardownBlock { try? self.deletable(imported.machineIdentifierURL) }

    XCTAssertThrowsError(try imported.importFromArchive(path: archive.path))
  }

  func testAnIdentifierThatCannotBeRemovedFailsANewMAC() throws {
    let vmDir = try linuxVM()
    try undeletable(vmDir.machineIdentifierURL)

    XCTAssertThrowsError(try vmDir.regenerateMACAddress())
  }

  private func readOnly(_ url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
    addTeardownBlock {
      try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }
  }

  // undeletable puts a directory at url that cannot be removed: a removal has
  // to empty it, and the directory inside it is not writable.
  private func undeletable(_ url: URL) throws {
    let locked = url.appendingPathComponent("locked")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    try touch(locked.appendingPathComponent("file"))
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    addTeardownBlock { try? self.deletable(url) }
  }

  private func deletable(_ url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: url.appendingPathComponent("locked").path)
  }

  private func exported(_ vmDir: VMDirectory) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tvm")
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }
    try vmDir.exportToArchive(path: url.path)
    return url
  }

  private func linuxVM() throws -> VMDirectory {
    let vmDir = try temporaryVMDirectory()
    try VMConfig(platform: Linux(), cpuCountMin: 2, memorySizeMin: 1024 * 1024 * 1024).save(toURL: vmDir.configURL)
    try touch(vmDir.nvramURL)
    try touch(vmDir.diskURL)
    return vmDir
  }

  private func temporaryVMDirectory() throws -> VMDirectory {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }

    return VMDirectory(baseURL: url)
  }

  private func touch(_ url: URL) throws {
    XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
  }
}
