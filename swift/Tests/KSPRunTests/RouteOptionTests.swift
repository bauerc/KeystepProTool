import KSPKit
import KSPMIDI
import Testing

@testable import KSPRun

/// The messages are compared exactly: they are part of the two CLIs' byte-for-byte contract.
@Suite struct RouteOptionTests {
    /// The message from a refusal, or `nil` if it was accepted.
    private func refusal(_ text: String) -> String? {
        do {
            _ = try parseRoutes(text)
            return nil
        } catch {
            return "\(error)"
        }
    }

    @Test func unsetRoutesNothing() throws {
        #expect(try parseRoutes(nil).isEmpty)
    }

    @Test func onePair() throws {
        #expect(try parseRoutes("3:1") == [TrackRoute(source: 3, device: 1)])
    }

    @Test func aCommaListKeepsItsOrder() throws {
        // Ordered, not a mapping: Swift's Dictionary iteration is nondeterministic.
        #expect(
            try parseRoutes("3:1,1:2") == [
                TrackRoute(source: 3, device: 1), TrackRoute(source: 1, device: 2),
            ])
    }

    @Test func whitespaceAroundItemsIsIgnored() throws {
        #expect(
            try parseRoutes(" 3 : 1 , 1 : 2 ") == [
                TrackRoute(source: 3, device: 1), TrackRoute(source: 1, device: 2),
            ])
    }

    @Test func aSignSurvivesToBeRefusedByRange() throws {
        // Out of range is ImportOptions' refusal to word, not the grammar's.
        #expect(try parseRoutes("-1:2") == [TrackRoute(source: -1, device: 2)])
    }

    @Test(arguments: ["3", "", "3:", ":1", "3:x", "x:3", "1:2:3", "1_0:2", "2:1,", "1:2,3"])
    func aMalformedPairIsRefused(text: String) {
        #expect(refusal(text)?.hasSuffix("is not a source:device pair") == true)
    }

    @Test func aMalformedPairIsQuotedWhole() {
        #expect(refusal("1:2:3") == "--route: '1:2:3' is not a source:device pair")
    }

    @Test func aMissingColonNamesTheItem() {
        #expect(refusal("3") == "--route: '3' is not a source:device pair")
    }

    @Test func anEmptyItemNamesItself() {
        #expect(refusal("2:1,") == "--route: '' is not a source:device pair")
    }

    @Test func aNonNumericHalfNamesTheItem() {
        #expect(refusal("3:x") == "--route: '3:x' is not a source:device pair")
        #expect(refusal("x:3") == "--route: 'x:3' is not a source:device pair")
    }

    @Test func anUnderscoreIsRefusedAlthoughPythonsIntTakesIt() {
        #expect(refusal("1_0:2") == "--route: '1_0:2' is not a source:device pair")
    }

    @Test(
        arguments: [
            "99999999999999999999:1", "1:99999999999999999999",
            // Int.min parses, so it must be bounded by magnitude: `abs` would overflow and trap.
            "-9223372036854775808:1",
            // Past 4300 digits Python's `int` raises its own message, so digits are counted first.
            String(repeating: "9", count: 5000) + ":1",
        ])
    func aNumberTooLargeToBeATrack(text: String) {
        #expect(refusal(text) == "--route: '\(text)' names a track number too large to be one")
    }
}
