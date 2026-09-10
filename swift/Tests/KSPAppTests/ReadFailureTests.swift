import Foundation
import KSPRun
import Testing

@testable import KSPApp

/// The wording a refused file gets. #282: the window showed the log line -- an absolute path and
/// a Swift case with its parentheses and nested quotes -- and offered no way out of it.
@Suite struct ReadFailureTests {
    private let path = URL(filePath: "/Users/someone/Music/bogus.mid")

    private func failure(
        _ reason: SummaryRunner.Failure.Reason, kind: Job.Kind = .toProject,
        detail: String = #"malformed("File header identifier is not correct.")"#,
        at path: URL? = nil
    ) -> ReadFailure {
        ReadFailure(
            SummaryRunner.Failure(reason, at: path ?? self.path, detail: detail), kind: kind)
    }

    @Test func amismatchedHeaderIsSaidInTheUsersWordsAndNotTheTypes() {
        let failure = failure(.unrecognised)

        #expect(failure.headline.hasPrefix("bogus.mid isn't a MIDI file"))
        #expect(!failure.headline.contains("malformed"))
        #expect(!failure.headline.contains("("))
    }

    /// The headline is a sentence, so the path it is about belongs on its own line beneath.
    @Test func thepathIsSecondaryRatherThanPartOfTheSentence() {
        let failure = failure(.unrecognised)

        #expect(!failure.headline.contains(path.path))
        #expect(failure.path == path.path)
    }

    @Test func arefusalOffersAWayOut() {
        #expect(failure(.unrecognised).headline.hasSuffix("Standard MIDI File."))
        #expect(
            failure(.unrecognised, kind: .toMIDI, at: URL(filePath: "/tmp/bogus.KeyStepPro"))
                .headline.hasSuffix("MIDI Control Center."))
    }

    /// Only the direction changes: what is wrong with a `.KeyStepPro` is not a MIDI header.
    @Test func aprojectIsRefusedAsAProjectRatherThanAsAMIDIFile() {
        let failure = failure(
            .unrecognised, kind: .toMIDI, detail: "could not parse: expected a key or } at byte 0",
            at: URL(filePath: "/tmp/bogus.KeyStepPro"))

        #expect(failure.headline.hasPrefix("bogus.KeyStepPro isn't a KeyStep Pro project"))
        #expect(!failure.headline.contains("byte 0"))
    }

    @Test func afileThatNeverOpenedIsNotCalledTheWrongFormat() {
        let failure = failure(.unopenable, detail: "The file couldn’t be opened.")

        #expect(failure.headline.hasPrefix("bogus.mid could not be opened."))
        #expect(!failure.headline.contains("isn't a MIDI file"))
    }

    /// The reader's own refusals are already written for a reader; only the type's are not.
    @Test func areadersRefusalKeepsTheReadersWords() {
        let failure = failure(.refused, detail: "midi_track counts from 1")

        #expect(failure.headline.contains("midi_track counts from 1"))
    }

    /// The band is one line wide, so its reason cannot be the headline.
    @Test func theblockReasonFitsBesideConvert() {
        #expect(failure(.unrecognised).blockReason.count < 60)
    }
}
