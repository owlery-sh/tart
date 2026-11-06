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

  // machineIdentifier is the VM's own, kept beside its NVRAM from its first run:
  // VZGenericPlatformConfiguration makes a new one each time otherwise, and a
  // saved state does not restore under another ("invalid argument").
  static func machineIdentifier(nvramURL: URL) throws -> VZGenericMachineIdentifier {
    let url = nvramURL.deletingLastPathComponent().appendingPathComponent(machineIdentifierFile)
    if let data = try? Data(contentsOf: url), let id = VZGenericMachineIdentifier(dataRepresentation: data) {
      return id
    }
    let id = VZGenericMachineIdentifier()
    try id.dataRepresentation.write(to: url, options: .atomic)
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
