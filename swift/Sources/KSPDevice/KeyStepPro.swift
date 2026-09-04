/// The attached device: finding it, and proving it answers.
public enum KeyStepPro {
    /// The endpoint pair CoreMIDI publishes for it; the device offers no second port.
    public static let endpointName = "KeyStep Pro"

    /// The device, and the firmware version no read address carries. The identity exchange is
    /// what decides it is there: an endpoint keeps accepting sends after it stops answering.
    public static func open(
        timeoutMs: Int = DeviceTransport.defaultTimeoutMs
    ) throws -> (device: DeviceTransport, version: String) {
        let device = try attach(timeoutMs: timeoutMs)
        return (device, try device.identify())
    }

    /// The device alone, for a caller that decides for itself whether to ask its identity.
    public static func attach(
        timeoutMs: Int = DeviceTransport.defaultTimeoutMs
    ) throws -> DeviceTransport {
        DeviceTransport(port: try CoreMIDIPort(named: endpointName), timeoutMs: timeoutMs)
    }
}
