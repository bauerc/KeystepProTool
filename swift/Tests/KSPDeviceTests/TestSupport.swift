import Foundation
import KSPKit
import KSPTape

@testable import KSPDevice

/// The frame the device would send back to `request`, carrying `values`. Echoes the request's own
/// header rather than rebuilding it through `KSPTape.buildReply`, which throws: these stand in as
/// the sentinel walk's `reread`, and that closure does not.
func reply(to request: [UInt8], values: [UInt8]) -> [UInt8] {
    var head = Array(request.dropLast())
    head[6] = head[6] == Sysex.cmdScalar ? Sysex.cmdScalarReply : Sysex.cmdReadReply
    return head + values + [Sysex.end]
}

/// The same frame as CoreMIDI delivers it: cut at the first sentinel, terminator intact (7.9.1).
func truncatedReply(to request: [UInt8], values: [UInt8]) -> [UInt8] {
    reply(to: request, values: Array(values.prefix { $0 != UInt8(Sysex.unset) }))
}

/// `123_117` across the sixteen patterns: the sentinel in 1-13 and 60 in 14-16 (7.9.1, H1.5).
let sentinelPatterns: [UInt8] = Array(repeating: UInt8(Sysex.unset), count: 13) + [60, 60, 60]

/// A long read of `count` values from `first`, the shape the sentinel range is walked at.
func patternRequest(from first: Int, count: Int) throws -> [UInt8] {
    try Sysex.buildReadRequest(
        ReadRequest(item: 123, param: 117, indices: [first], count: count))
}

/// Answers a long read out of `values`, truncating at the sentinel as CoreMIDI does.
func answerFromPatterns(_ request: [UInt8]) -> [UInt8] {
    let first = Int(request[request.count - 3])
    let count = Int(request[request.count - 2])
    let asked = Array(sentinelPatterns[(first - 1)..<(first - 1 + count)])
    return truncatedReply(to: request, values: asked)
}

/// A device that answers from a script rather than from the wire.
/// Synchronous throughout, so a test that waits out a timeout still runs instantly.
final class ScriptedPort: SysExPort {
    private let answer: ([UInt8]) -> [[UInt8]]
    private(set) var sent: [[UInt8]] = []
    private var pending: [[UInt8]] = []

    /// `answer` returns the frames the device puts on the wire for one request, in order.
    init(answer: @escaping ([UInt8]) -> [[UInt8]]) {
        self.answer = answer
    }

    /// Frames waiting before the first request, as a timed-out exchange would leave.
    func preload(_ frames: [[UInt8]]) {
        pending += frames
    }

    func send(_ frame: [UInt8]) throws {
        sent.append(frame)
        pending += answer(frame)
    }

    func nextFrame(within seconds: Double) -> [UInt8]? {
        pending.isEmpty ? nil : pending.removeFirst()
    }
}
