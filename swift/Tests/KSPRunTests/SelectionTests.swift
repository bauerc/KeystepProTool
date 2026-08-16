import KSPKit
import Testing

@testable import KSPRun

/// The `--tracks` / `--patterns` grammar, case for case with `tests/test_selection.py`. The
/// messages are compared exactly: they reach the user through the same byte-for-byte contract the
/// summaries do.
@Suite struct SelectionTests {
    private func parse(_ text: String?, limit: Int = 4) throws -> Set<Int> {
        try parseSelection(text, option: "--tracks", limit: limit)
    }

    /// The message from a refusal, or `nil` if it was accepted.
    private func refusal(_ text: String, limit: Int = 4) -> String? {
        do {
            _ = try parse(text, limit: limit)
            return nil
        } catch {
            return "\(error)"
        }
    }

    @Test func unsetMeansAll() throws {
        #expect(try parse(nil).isEmpty)
    }

    @Test func aSingleNumber() throws {
        #expect(try parse("3") == [3])
    }

    @Test func aCommaList() throws {
        #expect(try parse("1,3") == [1, 3])
    }

    @Test func aRangeCoversBothEnds() throws {
        #expect(try parse("2-5", limit: 16) == [2, 3, 4, 5])
    }

    @Test func aRangeOfOne() throws {
        #expect(try parse("2-2") == [2])
    }

    @Test func listsAndRangesMix() throws {
        #expect(try parse("1,3-5,8", limit: 16) == [1, 3, 4, 5, 8])
    }

    @Test func repeatsAndOverlapsCollapse() throws {
        #expect(try parse("1,1,1-2", limit: 16) == [1, 2])
    }

    @Test func whitespaceAroundItemsIsIgnored() throws {
        #expect(try parse(" 1 , 3 - 4 ", limit: 16) == [1, 3, 4])
    }

    @Test(arguments: ["x", "", "1,", "2-", "-3", "2-3-4", "1..3", "1_0", "--5"])
    func aMalformedItemIsRefused(text: String) {
        #expect(refusal(text, limit: 16)?.hasSuffix("is not a number or a range") == true)
    }

    @Test func aMalformedItemIsQuotedInTheMessage() {
        #expect(refusal("1,x") == "--tracks: 'x' is not a number or a range")
    }

    @Test(arguments: ["0", "5", "1,9", "3-9"])
    func outOfRangeIsRefused(text: String) {
        #expect(refusal(text)?.hasSuffix("is out of range 1-4") == true)
    }

    @Test func theOffendingNumberIsTheOneReported() {
        #expect(refusal("1,9") == "--tracks: 9 is out of range 1-4")
    }

    @Test func aRangeThatEndsBeforeItStarts() {
        #expect(refusal("4-2") == "--tracks: '4-2' ends before it starts")
    }

    @Test func theOptionNameIsTheCallersOwn() {
        #expect(
            throws: KSPError.value("--patterns: 99 is out of range 1-16"),
            performing: { try parseSelection("99", option: "--patterns", limit: 16) })
    }

    /// Python's ints are unbounded and Swift's are not, so a numeral too big for `Int` has to be
    /// reported as out of range rather than as unparseable, in the digits Python would print.
    @Test func aNumeralTooBigForIntIsStillOutOfRange() {
        #expect(
            refusal("99999999999999999999") == "--tracks: 99999999999999999999 is out of range 1-4")
        #expect(refusal("+00009") == "--tracks: 9 is out of range 1-4")
        // As the end of a range it is never the number reported: the walk stops at limit + 1
        // first, exactly as the unbounded Python arithmetic does.
        #expect(refusal("3-99999999999999999999") == "--tracks: 5 is out of range 1-4")
        #expect(refusal("0-99999999999999999999") == "--tracks: 0 is out of range 1-4")
        #expect(
            refusal("99999999999999999999-3")
                == "--tracks: '99999999999999999999-3' ends before it starts")
    }
}
