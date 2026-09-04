import KSPKit
import Testing

@testable import KSPDevice

@Suite struct SentinelTests {
    @Test func aWholeReplyIsNotShort() throws {
        let request = try patternRequest(from: 14, count: 3)
        #expect(
            Sentinel.shortfall(of: reply(to: request, values: [60, 60, 60]), to: request) == nil)
    }

    @Test func aTruncatedReplyIsShortByTheValuesThatArrived() throws {
        let request = try patternRequest(from: 12, count: 4)
        // Indices 12 and 13 hold the sentinel, so the cut is immediate.
        #expect(Sentinel.shortfall(of: answerFromPatterns(request), to: request) == 0)

        let later = try patternRequest(from: 14, count: 3)
        #expect(Sentinel.shortfall(of: answerFromPatterns(later), to: later) == nil)
    }

    @Test func aScalarReplyIsNeverJudgedShort() throws {
        let request = try Sysex.buildReadRequest(ReadRequest(item: 120, param: 37))
        #expect(Sentinel.shortfall(of: reply(to: request, values: [3]), to: request) == nil)
    }

    @Test func theSentinelLandsWhereTheReplyStopped() throws {
        let request = try patternRequest(from: 13, count: 4)
        let (frame, repairs) = try Sentinel.repair(
            request, answerFromPatterns(request), carried: 0, reread: answerFromPatterns)

        let (answered, values) = try Sysex.parseReply(frame)
        #expect(answered == ReadRequest(item: 123, param: 117, indices: [13], count: 4))
        #expect(values == [Sysex.unset, 60, 60, 60])
        #expect(repairs == 1)
    }

    @Test func thirteenSentinelsInARowAreAllRecovered() throws {
        let request = try patternRequest(from: 1, count: 16)
        let truncated = answerFromPatterns(request)
        // What bulk_fast issues, and what the whole range is lost to: sixteen asked, none back.
        #expect(Sentinel.shortfall(of: truncated, to: request) == 0)

        let (frame, repairs) = try Sentinel.repair(
            request, truncated, carried: 0, reread: answerFromPatterns)

        let (answered, values) = try Sysex.parseReply(frame)
        #expect(answered == ReadRequest(item: 123, param: 117, indices: [1], count: 16))
        #expect(values == sentinelPatterns.map(Int.init))
        #expect(repairs == 13)
    }

    @Test func aSentinelAtTheLastIndexEndsTheRepair() throws {
        // 1-13 of the range arrive; only index 14 is missing, and it is the last.
        let values: [UInt8] = Array(repeating: 60, count: 13) + [UInt8(Sysex.unset)]
        let request = try patternRequest(from: 1, count: 14)
        let truncated = truncatedReply(to: request, values: values)

        let (frame, repairs) = try Sentinel.repair(
            request, truncated, carried: 13,
            reread: { _ in
                Issue.record("nothing is left to re-read")
                return []
            })

        #expect(try Sysex.parseReply(frame).values == values.map(Int.init))
        #expect(repairs == 1)
    }

    @Test func aReReadPastTheSeventhBitIsRefusedRatherThanMalformed() throws {
        // A request the plan never issues, but poking a byte past 0x7F would build a frame the
        // device cannot parse, so the repair stops instead.
        let request = try Sysex.buildReadRequest(
            ReadRequest(item: 123, param: 117, indices: [120], count: 16))
        let truncated = reply(to: request, values: [])

        #expect(throws: DeviceError.self) {
            try Sentinel.repair(request, truncated, carried: 0, reread: { $0 })
        }
    }

    @Test func theRepairedFrameEchoesTheAddressItWasAskedFor() throws {
        let request = try patternRequest(from: 1, count: 16)
        let (frame, _) = try Sentinel.repair(
            request, answerFromPatterns(request), carried: 0, reread: answerFromPatterns)
        #expect(Array(frame.prefix(6)) == Sysex.header)
        #expect(try Sysex.parseSlot(frame) == Sysex.defaultSlot)
        #expect(try Sysex.parseReply(frame).request.count == 16)
    }
}
