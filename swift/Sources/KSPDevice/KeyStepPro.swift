public enum KeyStepPro {
    public static let endpointName = "KeyStep Pro"

    /// The device, and the firmware version no read address carries. The identity exchange is
    /// what decides it is there: an endpoint keeps accepting sends after it stops answering.
    public static func open(
        timeoutMs: Int = DeviceTransport.defaultTimeoutMs
    ) throws -> (device: DeviceTransport, version: String) {
        let device = try attach(timeoutMs: timeoutMs)
        return (device, try device.identify())
    }

    public static func attach(
        timeoutMs: Int = DeviceTransport.defaultTimeoutMs
    ) throws -> DeviceTransport {
        DeviceTransport(port: try CoreMIDIPort(named: endpointName), timeoutMs: timeoutMs)
    }
}
