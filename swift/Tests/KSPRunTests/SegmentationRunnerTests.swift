import Foundation
import KSPKit
import KSPMIDI
import SwiftMIDIFile
import Testing

@testable import KSPRun

private func options(
    _ name: String, midiTracksSpec: String? = nil, midiTrack: Int? = nil, track: Int = 1,
    pattern: Int = 1
) -> ConvertRunner.Options {
    ConvertRunner.Options(
        paths: [RepoData.projectFiles.appending(path: name)], track: track, pattern: pattern,
        midiTrack: midiTrack, midiTracksSpec: midiTracksSpec,
        configPath: noPersonalConfig)
}

@Suite struct SegmentationRunnerTests {
    @Test func itreadsTheFileAndSaysWhatTheImportWouldLayDown() throws {
        let outcome = SegmentationRunner.run(options("m6-test-file.mid"))

        #expect(outcome.message == nil)
        let summary = try #require(outcome.summary)
        #expect(summary.tracks.map(\.deviceTrack) == [1, 2, 3, 4])
        #expect(summary.tracks.map(\.sourceTrack) == [3, 4, 5, 6])
        #expect(summary.tracks[3].segments.map(\.pattern) == [1, 2])
    }

    /// The same file through the runner and through the planner by hand: the runner adds no
    /// arithmetic of its own on the way.
    @Test func therunnerAgreesWithThePlannerItCalls() throws {
        let path = RepoData.projectFiles.appending(path: "m6-test-file.mid")
        let midi = try MusicalMIDI1File(data: Data(contentsOf: path))
        let song = try MIDIImport.readSongs([Source("m6-test-file.mid", midi)])
        let plan = try MIDIImport.planSong(song)

        let summary = try #require(SegmentationRunner.run(options("m6-test-file.mid")).summary)

        #expect(summary.tracks.map(\.deviceTrack) == plan.tracks.map(\.track))
        #expect(
            summary.tracks.map { $0.segments.map(\.stepCount) }
                == plan.tracks.map { $0.placements.map(\.stepCount) })
    }

    /// A file that will not read says so rather than leaving an empty preview to be read as an
    /// import that would lay nothing down.
    @Test func afileThatWillNotReadSaysSoRatherThanPreviewingNothing() {
        let unreadable = SegmentationRunner.run(options("no-such-file.mid"))

        #expect(unreadable.summary == nil)
        #expect(unreadable.message != nil)
    }

    /// The selection criterion: unticking a source track changes what the preview says.
    @Test func aselectionNarrowsWhatWouldBeLaidDown() throws {
        let outcome = SegmentationRunner.run(options("m6-test-file.mid", midiTracksSpec: "3,4"))

        let summary = try #require(outcome.summary)
        #expect(summary.tracks.map(\.sourceTrack) == [3, 4])
        #expect(summary.unplaced.isEmpty)
    }

    @Test func routingIsFollowedSoTheViewCanShowIt() throws {
        let outcome = SegmentationRunner.run(
            options("m6-test-file.mid", midiTracksSpec: "3", track: 2, pattern: 5))

        let summary = try #require(outcome.summary)
        #expect(summary.tracks.map(\.deviceTrack) == [2])
        #expect(summary.tracks[0].segments.map(\.pattern) == [5])
    }

    @Test func amissingFileIsReportedRatherThanCrashing() {
        let outcome = SegmentationRunner.run(options("no-such-file.mid"))

        #expect(outcome.summary == nil)
        #expect(outcome.message != nil)
    }

    @Test func afileThatIsNotMIDIIsReported() throws {
        let path = try tempFile("not a midi file", suffix: ".mid")
        defer { try? FileManager.default.removeItem(at: path) }

        let outcome = SegmentationRunner.run(
            ConvertRunner.Options(paths: [path], configPath: noPersonalConfig))

        #expect(outcome.summary == nil)
        #expect(outcome.message != nil)
    }

    /// The single-target path quantises to the template's own pattern length, which a preview that
    /// reads no template cannot know.
    @Test func thesingleTargetPathIsDeclinedRatherThanGuessedAt() {
        let outcome = SegmentationRunner.run(options("m6-test-file.mid", midiTrack: 3))

        #expect(outcome.summary == nil)
        #expect(outcome.message != nil)
    }

    @Test func aplanIsNotAConversionAndLeavesNoFileBehind() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ksp-seg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appending(path: "m6-test-file.mid")
        try FileManager.default.copyItem(
            at: RepoData.projectFiles.appending(path: "m6-test-file.mid"), to: copy)

        let outcome = SegmentationRunner.run(
            ConvertRunner.Options(paths: [copy], configPath: noPersonalConfig))

        #expect(outcome.summary != nil)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left == ["m6-test-file.mid"])
    }
}
