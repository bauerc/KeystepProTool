public protocol SysExPort {
    func send(_ frame: [UInt8]) throws

    func nextFrame(within seconds: Double) -> [UInt8]?
}

extension SysExPort {
    /// Whatever a timed-out exchange left behind, so a late reply cannot answer the next request.
    func drain() {
        while nextFrame(within: 0) != nil {}
    }
}
