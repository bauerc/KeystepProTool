import Foundation

/// Whole SysEx messages off a MIDI input port, as a blocking queue.
/// CoreMIDI delivers a reply split across packets, so the reassembly is here rather than above.
final class FrameQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var queue: [[UInt8]] = []
    private let arrived = DispatchSemaphore(value: 0)

    /// Called from CoreMIDI's own thread.
    func feed(_ bytes: [UInt8]) {
        var completed = 0
        lock.lock()
        for byte in bytes {
            // Real-time bytes may interleave a SysEx stream. `0xFF` is not one of them here: it
            // never reaches us at all, because CoreMIDI cuts the frame at it (spec 7.9.1).
            if (0xF8...0xFE).contains(byte) { continue }
            if byte == 0xF0 {
                pending = [byte]
            } else if !pending.isEmpty {
                pending.append(byte)
                if byte == 0xF7 {
                    queue.append(pending)
                    pending = []
                    completed += 1
                }
            }
        }
        lock.unlock()
        for _ in 0..<completed { arrived.signal() }
    }

    func next(within seconds: Double) -> [UInt8]? {
        guard arrived.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return queue.isEmpty ? nil : queue.removeFirst()
    }
}
