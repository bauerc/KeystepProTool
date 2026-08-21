import KSPKit
import KSPMIDI
import Testing

@testable import KSPRun

/// The `--route` grammar, case for case with `tests/test_route_option.py`. The messages are
/// compared exactly: they reach the user through the same byte-for-byte contract the summaries do.
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
        // Ordered, not a mapping: the two cores are a byte-for-byte contract and Swift's
        // Dictionary iteration is nondeterministic.
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
        // `1_0` and a non-ASCII digit are refused although Python's `int` takes both: the two
        // cores refuse the same input.
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

    @Test(arguments: ["99999999999999999999:1", "1:99999999999999999999"])
    func aNumberTooLargeToBeATrack(text: String) {
        // Python's ints are unbounded and Swift's are not, so an oversized numeral is refused
        // here rather than reaching a range message that would print it.
        #expect(refusal(text) == "--route: '\(text)' names a track number too large to be one")
    }
}
