import KSPKit
import KSPMIDI
import Testing

@testable import KSPRun

/// The messages are compared exactly: they are part of the two CLIs' byte-for-byte contract.
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
        // Range-checking is ExportOptions' job, so both cores raise the identical message.
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

    /// Python's ints are unbounded, so an oversized numeral must still reach the range message.
    @Test func aNumeralTooBigForIntSaturatesRatherThanRefusing() throws {
        #expect(try parseFlatVelocity("99999999999999999999") == Int.max)
    }
}
