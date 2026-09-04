/// A pair of MIDI endpoints as whole SysEx frames: the wire under `DeviceTransport`.
/// Public so a replay of a captured session can stand in for the hardware.
public protocol SysExPort {
    func send(_ frame: [UInt8]) throws

    /// The next complete frame, or nil once `seconds` have passed without one.
    func nextFrame(within seconds: Double) -> [UInt8]?
}

extension SysExPort {
    /// Whatever a timed-out exchange left behind, so a late reply cannot answer the next request.
    func drain() {
        while nextFrame(within: 0) != nil {}
    }
}
