import KSPKit
import Testing

@testable import KSPDevice

@Suite struct FrameQueueTests {
    @Test func aFrameSplitAcrossPacketsIsReassembled() throws {
        let frame = try patternRequest(from: 14, count: 3)
        let queue = FrameQueue()

        // CoreMIDI delivers three bytes at a time, so no real reply arrives whole.
        for chunk in stride(from: 0, to: frame.count, by: 3) {
            queue.feed(Array(frame[chunk..<min(chunk + 3, frame.count)]))
            if chunk + 3 < frame.count {
                #expect(queue.next(within: 0) == nil)
            }
        }
        #expect(queue.next(within: 0) == frame)
    }

    @Test func realTimeBytesDoNotEnterAFrame() {
        let queue = FrameQueue()
        // Clock and active sensing may interleave a SysEx stream at any byte boundary.
        queue.feed([0xF0, 0xF8, 0x01, 0xFE, 0x02, 0xF7])

        #expect(queue.next(within: 0) == [0xF0, 0x01, 0x02, 0xF7])
    }

    @Test func twoFramesInOneRunBothArrive() {
        let queue = FrameQueue()
        queue.feed([0xF0, 0x01, 0xF7, 0xF0, 0x02, 0xF7])

        #expect(queue.next(within: 0) == [0xF0, 0x01, 0xF7])
        #expect(queue.next(within: 0) == [0xF0, 0x02, 0xF7])
        #expect(queue.next(within: 0) == nil)
    }

    @Test func bytesBeforeTheFirstStatusAreIgnored() {
        let queue = FrameQueue()
        // A run joined mid-frame, or channel traffic from the device's own keyboard.
        queue.feed([0x40, 0x7F, 0x90, 0xF0, 0x03, 0xF7])

        #expect(queue.next(within: 0) == [0xF0, 0x03, 0xF7])
    }

    @Test func anAbandonedFrameIsReplacedByTheNextOne() {
        let queue = FrameQueue()
        queue.feed([0xF0, 0x01, 0x02])
        queue.feed([0xF0, 0x03, 0xF7])

        #expect(queue.next(within: 0) == [0xF0, 0x03, 0xF7])
    }

    @Test func waitingOnAnEmptyQueueTimesOut() {
        #expect(FrameQueue().next(within: 0.01) == nil)
    }
}
