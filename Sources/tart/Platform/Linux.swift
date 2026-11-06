import Virtualization

@available(macOS 13, *)
struct Linux: PlatformSuspendable {
  func os() -> OS {
    .linux
  }

  func bootLoader(nvramURL: URL) throws -> VZBootLoader {
    let result = VZEFIBootLoader()

    result.variableStore = VZEFIVariableStore(url: nvramURL)

    return result
  }

  func platform(nvramURL: URL, needsNestedVirtualization: Bool) throws -> VZPlatformConfiguration {
    let config = VZGenericPlatformConfiguration()
    config.machineIdentifier = try Linux.machineIdentifier(nvramURL: nvramURL)
    if #available(macOS 15, *) {
      config.isNestedVirtualizationEnabled = needsNestedVirtualization
    }
    return config
  }

  static let machineIdentifierFile = "machine-identifier"

  // An identifier's data representation is a few dozen bytes; a file far bigger
  // than that is not one.
  static let machineIdentifierMaxSize = 4096

  // machineIdentifier is the VM's own, kept beside its NVRAM from its first run:
  // VZGenericPlatformConfiguration makes a new one each time otherwise, and a
  // saved state does not restore under another ("invalid argument"). Only a
  // missing file makes a new one: one that cannot be read is an error, and is
  // left as it is. A VM with a saved state and no identifier cannot be restored,
  // so it is an error too, never a new identifier.
  static func machineIdentifier(nvramURL: URL) throws -> VZGenericMachineIdentifier {
    let dir = nvramURL.deletingLastPathComponent()
    let url = dir.appendingPathComponent(machineIdentifierFile)
    if let id = try readMachineIdentifier(url) {
      return id
    }
    if FileManager.default.fileExists(atPath: VMDirectory(baseURL: dir).stateURL.path) {
      throw RuntimeError.VMConfigurationError("VM has a saved state but no \(machineIdentifierFile), "
        + "so the state cannot be restored; delete state.vzvmsave to boot it from its disk")
    }
    let id = VZGenericMachineIdentifier()
    try id.dataRepresentation.write(to: url, options: .atomic)
    return id
  }

  // readMachineIdentifier is the identifier kept at url, or nil if there is none.
  static func readMachineIdentifier(_ url: URL) throws -> VZGenericMachineIdentifier? {
    let attrs: [FileAttributeKey: Any]
    do {
      attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
      return nil
    }
    guard attrs[.type] as? FileAttributeType == .typeRegular else {
      throw RuntimeError.VMConfigurationError("\(url.path) is not a regular file")
    }
    guard let size = attrs[.size] as? Int, size <= machineIdentifierMaxSize else {
      throw RuntimeError.VMConfigurationError("\(url.path) is too big to be a machine identifier")
    }
    guard let id = VZGenericMachineIdentifier(dataRepresentation: try Data(contentsOf: url)) else {
      throw RuntimeError.VMConfigurationError("\(url.path) is not a machine identifier")
    }
    return id
  }

  func graphicsDevice(vmConfig: VMConfig) -> VZGraphicsDeviceConfiguration {
    let result = VZVirtioGraphicsDeviceConfiguration()

    result.scanouts = [
      VZVirtioGraphicsScanoutConfiguration(
        widthInPixels: vmConfig.display.width,
        heightInPixels: vmConfig.display.height
      )
    ]

    return result
  }

  func keyboards(noUSB: Bool) -> [VZKeyboardConfiguration] {
    noUSB ? [] : [VZUSBKeyboardConfiguration()]
  }

  func pointingDevices(noUSB: Bool) -> [VZPointingDeviceConfiguration] {
    noUSB ? [] : [VZUSBScreenCoordinatePointingDeviceConfiguration()]
  }

  func pointingDevicesSimplified(noUSB: Bool) -> [VZPointingDeviceConfiguration] {
    // Linux doesn't support trackpad, so just return the regular pointing devices
    return pointingDevices(noUSB: noUSB)
  }

  // A suspendable Linux VM has no keyboard or pointer: it is driven over the
  // network and vsock, and its USB input devices are what a restore of a VM that
  // had been restored before failed on ("Internal Virtualization error").
  func keyboardsSuspendable(noUSB: Bool) -> [VZKeyboardConfiguration] {
    []
  }

  func pointingDevicesSuspendable(noUSB: Bool) -> [VZPointingDeviceConfiguration] {
    []
  }
}
