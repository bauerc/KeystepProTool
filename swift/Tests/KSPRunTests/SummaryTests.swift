import Foundation
import KSPKit
import Testing

@testable import KSPRun

/// `project_5`'s counts are the hand-transcribed ground truth in `tests/fixtures/`.
@Suite struct SummaryTests {
    static func summarise(_ name: String) throws -> ProjectSummary {
        let result = SummaryRunner.run(
            SummaryRunner.Options(path: RepoData.projectFiles.appending(path: name)))
        #expect(result.message == nil)
        return try #require(result.summary)
    }

    @Test func itReportsEveryTrackAndEveryPatternSlot() throws {
        let summary = try Self.summarise("user_empty_project.KeyStepPro")
        #expect(summary.tracks.count == 4)
        #expect(summary.tracks.map(\.number) == [1, 2, 3, 4])
        for track in summary.tracks {
            #expect(track.patterns.count == 16)
            #expect(track.patterns.map(\.number) == Array(1...16))
            #expect(track.isEmpty)
        }
        #expect(summary.isEmpty)
    }

    @Test func itCarriesTheProjectHeader() throws {
        let summary = try Self.summarise("project_5.KeyStepPro")
        #expect(summary.sourceName == "project_5.KeyStepPro")
        #expect(summary.tempoBPM == 120.0)
        #expect(summary.globalSwingPercent == 50)
        #expect(summary.currentScene == 1)
    }

    @Test func itNamesATrackAsTheExportedFileNamesIt() throws {
        let summary = try Self.summarise("project_5.KeyStepPro")
        #expect(summary.tracks[0].name == "Track 1 (drum)")
        #expect(summary.tracks[0].mode == .drum)
        #expect(summary.tracks[2].name == "Track 3")
        #expect(summary.tracks[2].mode == .sequencer)
    }

    @Test func itCountsTheNotesTheDescriptionRecords() throws {
        // From tests/fixtures/project_5.expected.json.
        let summary = try Self.summarise("project_5.KeyStepPro")
        let drum = summary.tracks[0].patterns[0]
        #expect(drum.noteCount == 2)
        #expect(drum.mode == .drum)
        #expect(!drum.isEmpty)
        #expect(drum.isEnabled)

        let melodic = summary.tracks[2].patterns[0]
        #expect(melodic.noteCount == 10)
        #expect(melodic.mode == .seq)
        #expect(melodic.isEnabled)

        #expect(summary.tracks[1].isEmpty)
        #expect(summary.tracks[3].isEmpty)
        #expect(summary.tracks[0].patterns.dropFirst().allSatisfy { $0.isEmpty })
    }

    @Test func itReportsTheLiveSetsStepCount() throws {
        let summary = try Self.summarise("project_5.KeyStepPro")
        // Track 1 is in drum mode, so the drum step count is the one that governs it.
        #expect(summary.tracks[0].patterns[0].stepCount == 16)
        #expect(summary.tracks[2].patterns[0].stepCount == 16)
    }

    @Test func itKeepsTheHasDataLatchApartFromEmptiness() throws {
        // project_9's first pattern has parameter 40 set while holding no notes.
        let summary = try Self.summarise("project_9.KeyStepPro")
        let pattern = summary.tracks[0].patterns[0]
        #expect(pattern.hasData)
        #expect(pattern.noteCount == 0)
        #expect(pattern.isEmpty)
        #expect(!pattern.isEnabled)
    }

    @Test func itCountsWhatIsSwitchedOnRatherThanWhatThePoolHolds() throws {
        // initial_project is the only sample holding disabled notes.
        let summary = try Self.summarise("initial_project.KeyStepPro")
        // 64 of the 76 are melodic leftovers from before the track was switched to drums.
        let crowded = summary.tracks[0].patterns[0]
        #expect(crowded.mode == .drum)
        #expect(crowded.noteCount == 76)
        #expect(crowded.enabledNoteCount == 8)
        #expect(crowded.stepCount == 16)
        #expect(!crowded.isEmpty)
        #expect(crowded.isEnabled)
        #expect(
            summary.tracks.flatMap(\.patterns).allSatisfy { $0.enabledNoteCount <= $0.noteCount }
        )
    }

    @Test func itReportsNoChainWhereTheFileHoldsNone() throws {
        // No sample in the repository chains anything, so this is the whole corpus's answer.
        for name in ["project_5.KeyStepPro", "project_9.KeyStepPro", "initial_project.KeyStepPro"] {
            let summary = try Self.summarise(name)
            #expect(summary.tracks.allSatisfy { $0.chain.isEmpty })
            #expect(summary.tracks.flatMap(\.patterns).allSatisfy { $0.chain.isEmpty })
        }
    }

    @Test func itGivesEveryChainedPatternTheChainItSitsIn() {
        // Built here rather than read: the corpus has no chain to read.
        let project = Project(
            device: "KeyStep Pro", version: nil, tempoBPM: 120, globalSwingPercent: 50,
            currentScene: 2,
            tracks: (1...4).map(chainTrack),
            scenes: [
                Scene(number: 1, chains: [Chain(track: 1, patterns: [9, 10])]),
                Scene(number: 2, chains: [Chain(track: 1, patterns: [3, 1, 2])]),
            ])
        let summary = ProjectSummary(project)

        // The current Scene decides, so scene 1's chain is not what is reported.
        #expect(summary.tracks[0].chain == [3, 1, 2])
        #expect(summary.tracks[0].patterns[0].chain == [3, 1, 2])
        #expect(summary.tracks[0].patterns[2].chain == [3, 1, 2])
        #expect(summary.tracks[0].patterns[3].chain.isEmpty)
        #expect(summary.tracks[1].chain.isEmpty)
        #expect(summary.tracks[1].patterns.allSatisfy { $0.chain.isEmpty })
    }

    @Test func itReportsAnUnreadableFileInsteadOfAnEmptySummary() {
        let missing = SummaryRunner.run(
            SummaryRunner.Options(path: RepoData.projectFiles.appending(path: "nope.KeyStepPro")))
        #expect(missing.summary == nil)
        #expect(missing.message?.isEmpty == false)

        let wrongFormat = SummaryRunner.run(
            SummaryRunner.Options(path: RepoData.projectFiles.appending(path: "test_file.mid")))
        #expect(wrongFormat.summary == nil)
        #expect(wrongFormat.message?.isEmpty == false)
    }
}

private func chainTrack(_ number: Int) -> Track {
    Track(
        number: number, itemID: Constants.trackItemIDs[number - 1],
        patterns: (1...16).map { slot in
            Pattern(
                number: slot, mode: .empty, hasData: false, seqStepCount: 16, seqSwingPercent: 50,
                seqBits: PatternBits.decode(0), drumStepCount: nil, drumSwingPercent: nil,
                drumBits: nil, rootNote: 0, scale: 0, notes: [])
        })
}
