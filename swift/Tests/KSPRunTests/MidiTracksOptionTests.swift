import KSPKit
import Testing

@testable import KSPRun

/// The messages are compared exactly: they are part of the two CLIs' byte-for-byte contract.
@Suite struct MidiTracksOptionTests {
    /// The message from a refusal, or `nil` if it was accepted.
    private func refusal(_ single: Int?, _ listed: String?) -> String? {
        do {
            _ = try resolveMidiTracks(single, listed)
            return nil
        } catch {
            return "\(error)"
        }
    }

    @Test func neitherSpellingSelectsNothing() throws {
        #expect(try resolveMidiTracks(nil, nil).isEmpty)
    }

    @Test func theSingleSpellingIsItsOwnSet() throws {
        #expect(try resolveMidiTracks(3, nil) == [3])
    }

    /// ImportOptions words the refusal for --midi-track, as it did before --midi-tracks existed.
    @Test func theSingleSpellingKeepsAnOutOfRangeNumber() throws {
        #expect(try resolveMidiTracks(0, nil) == [0])
    }

    @Test func aCommaList() throws {
        #expect(try resolveMidiTracks(nil, "1,2,5") == [1, 2, 5])
    }

    @Test func aRange() throws {
        #expect(try resolveMidiTracks(nil, "2-4") == [2, 3, 4])
    }

    @Test func aListOfRangesAndNumbers() throws {
        #expect(try resolveMidiTracks(nil, "1,3-5") == [1, 3, 4, 5])
    }

    @Test(arguments: ["bad", "", "1_0", "1,", "1-"])
    func aMalformedItemNamesItself(_ text: String) {
        #expect(refusal(nil, text)?.contains("is not a number or a range") == true)
    }

    @Test func aBackwardRange() {
        #expect(refusal(nil, "3-1") == "--midi-tracks: '3-1' ends before it starts")
    }

    @Test func zeroIsOutOfRange() {
        #expect(refusal(nil, "0") == "--midi-tracks: 0 is out of range 1-65535")
    }

    /// A Standard MIDI File counts its tracks in 16 bits, so nothing above this can exist.
    @Test func aNumberPastTheFileFormatIsOutOfRange() {
        #expect(refusal(nil, "65536") == "--midi-tracks: 65536 is out of range 1-65535")
    }

    /// Python's ints are unbounded and Swift's saturate; both must print these digits.
    @Test func anOversizedNumeralIsPrintedAsWritten() {
        #expect(
            refusal(nil, "99999999999999999999")
                == "--midi-tracks: 99999999999999999999 is out of range 1-65535")
    }

    @Test func theTwoSpellingsContradictEachOther() {
        #expect(
            refusal(1, "1")?.hasPrefix("--midi-track and --midi-tracks contradict each other")
                == true)
    }
}
