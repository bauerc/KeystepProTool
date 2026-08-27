import KSPKit
import KSPMIDI
import Testing

@testable import KSPRun

/// The messages are compared exactly: they are part of the two CLIs' byte-for-byte contract.
@Suite struct SegmentBarsOptionTests {
    private func parse(_ text: String?) throws -> [TrackSegments] {
        try resolveSegments(nil, text)
    }

    /// The message from a refusal, or `nil` if it was accepted.
    private func refusal(_ text: String) -> String? {
        do {
            _ = try parse(text)
            return nil
        } catch {
            return "\(error)"
        }
    }

    @Test func unsetSegmentsNothing() throws {
        #expect(try parse(nil).isEmpty)
    }

    @Test func onePair() throws {
        #expect(try parse("3:5") == [TrackSegments(source: 3, bars: [5])])
    }

    @Test func pairsNamingOneTrackGatherIntoItsBars() throws {
        #expect(try parse("2:5,2:9") == [TrackSegments(source: 2, bars: [5, 9])])
    }

    @Test func aCommaListKeepsItsOrder() throws {
        // Ordered, not a mapping: Swift's Dictionary iteration is nondeterministic.
        #expect(
            try parse("3:3,2:5") == [
                TrackSegments(source: 3, bars: [3]), TrackSegments(source: 2, bars: [5]),
            ])
    }

    @Test func aTrackHoldsThePlaceItFirstTook() throws {
        #expect(
            try parse("2:5,3:3,2:9") == [
                TrackSegments(source: 2, bars: [5, 9]), TrackSegments(source: 3, bars: [3]),
            ])
    }

    @Test func whitespaceAroundItemsIsIgnored() throws {
        #expect(try parse(" 2 : 5 , 2 : 9 ") == [TrackSegments(source: 2, bars: [5, 9])])
    }

    @Test func aSignSurvivesToBeRefusedByRange() throws {
        // Out of range is ImportOptions' refusal to word, not the grammar's.
        #expect(try parse("-1:5") == [TrackSegments(source: -1, bars: [5])])
    }

    @Test(arguments: ["3", "", "3:", ":5", "3:x", "x:3", "1:2:3", "1_0:2", "2:5,", "2:5,3"])
    func aMalformedPairIsRefused(text: String) {
        #expect(refusal(text)?.hasSuffix("is not a source:bar pair") == true)
    }

    @Test func aMalformedPairIsQuotedWhole() {
        #expect(refusal("1:2:3") == "--segment-bars: '1:2:3' is not a source:bar pair")
    }

    @Test func aMissingColonNamesTheItem() {
        #expect(refusal("3") == "--segment-bars: '3' is not a source:bar pair")
    }

    @Test func anEmptyItemNamesItself() {
        #expect(refusal("2:5,") == "--segment-bars: '' is not a source:bar pair")
    }

    @Test func aNonNumericHalfNamesTheItem() {
        #expect(refusal("3:x") == "--segment-bars: '3:x' is not a source:bar pair")
        #expect(refusal("x:3") == "--segment-bars: 'x:3' is not a source:bar pair")
    }

    @Test func anUnderscoreIsRefusedAlthoughPythonsIntTakesIt() {
        #expect(refusal("1_0:2") == "--segment-bars: '1_0:2' is not a source:bar pair")
    }

    @Test(
        arguments: [
            "99999999999999999999:5", "5:99999999999999999999",
            // Int.min parses, so it must be bounded by magnitude: `abs` would overflow and trap.
            "-9223372036854775808:1",
            // Past 4300 digits Python's `int` raises its own message, so digits are counted first.
            String(repeating: "9", count: 5000) + ":1",
        ])
    func aNumberTooLargeToBeOne(text: String) {
        #expect(refusal(text) == "--segment-bars: '\(text)' names a number too large to be one")
    }

    @Test func aSingleTargetAndASegmentationContradictEachOther() {
        var message: String?
        do {
            _ = try resolveSegments(1, "1:5")
        } catch {
            message = "\(error)"
        }
        #expect(
            message
                == "--midi-track and --segment-bars contradict each other; --midi-track converts "
                + "one source track into the one pattern the target names, and a segmentation "
                + "cuts a track across several")
    }

    @Test func aSingleTargetAloneSegmentsNothing() throws {
        #expect(try resolveSegments(1, nil).isEmpty)
    }
}
