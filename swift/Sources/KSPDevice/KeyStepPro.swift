/// The attached device: finding it, and proving it answers.
public enum KeyStepPro {
    /// The endpoint pair CoreMIDI publishes for it; the device offers no second port.
    public static let endpointName = "KeyStep Pro"

    /// The device, and the firmware version its identity reply carries -- which no read address
    /// holds, and which a byte-identical file needs.
    ///
    /// The identity exchange is what decides the device is there: an endpoint stays published,
    /// and keeps accepting sends, after the device has stopped answering (spec 7.9.2).
    public static func open(
        timeoutMs: Int = DeviceTransport.defaultTimeoutMs
    ) throws -> (device: DeviceTransport, version: String) {
        let device = DeviceTransport(
            port: try CoreMIDIPort(named: endpointName), timeoutMs: timeoutMs)
        return (device, try device.identify())
    }
}
