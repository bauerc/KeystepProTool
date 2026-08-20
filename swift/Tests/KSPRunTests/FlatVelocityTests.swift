import KSPKit
import KSPMIDI
import Testing

@testable import KSPRun

/// The `--flat-velocity` grammar, case for case with `tests/test_flat_velocity.py`. The messages
/// are compared exactly: they reach the user through the same byte-for-byte contract the summaries
/// do.
@Suite struct FlatVelocityTests {
    /// The message from a refusal, or `nil` if it was accepted.
    private func refusal(_ text: String) -> String? {
        do {
            _ = try parseFlatVelocity(text)
            return nil
        } catch {
            return "\(error)"
        }
    }

    @Test func absentMeansTheStoredVelocity() throws {
        #expect(try parseFlatVelocity(nil) == nil)
    }

    @Test func freshIsTheMeasuredDefault() throws {
        #expect(try parseFlatVelocity("fresh") == MIDIExport.defaultFlatVelocity)
    }

    @Test func aNumberPassesThroughUnvalidated() throws {
        // Range-checking is ExportOptions' job, not this function's -- 0 and 999 are both
        // accepted here so the two cores raise the identical message for them.
        #expect(try parseFlatVelocity("64") == 64)
        #expect(try parseFlatVelocity("0") == 0)
        #expect(try parseFlatVelocity("999") == 999)
    }

    @Test(arguments: ["x", "", "loud", "1.5", "-5", "+5", "1_0"])
    func aMalformedValueIsRefused(text: String) {
        #expect(refusal(text)?.hasSuffix("is not 'fresh' or a velocity") == true)
    }

    @Test func theValueIsQuotedInTheMessage() {
        #expect(refusal("loud") == "--flat-velocity: 'loud' is not 'fresh' or a velocity")
    }

    /// Python's ints are unbounded and Swift's are not, so a numeral too big for `Int` has to
    /// still reach the range message rather than "is not 'fresh' or a velocity".
    @Test func aNumeralTooBigForIntSaturatesRatherThanRefusing() throws {
        #expect(try parseFlatVelocity("99999999999999999999") == Int.max)
    }
}
