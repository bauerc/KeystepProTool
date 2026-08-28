import Foundation
import KSPKit
import KSPMIDI
import SwiftMIDIFile
import Testing

@testable import KSPRun

private let ticksPerBeat = 480

/// A quarter-note per step at the default four steps to the beat.
private let ticksPerStep = 120

private func note(_ tick: Int, pitch: Int = 60, channel: Int = 0) -> RenderedNote {
    RenderedNote(
        tick: tick, durationTicks: ticksPerStep, pitch: pitch, velocity: 100, channel: channel)
}

private func clip(source: Int, notes count: Int, channel: Int = 0, file: String = "") -> Clip {
    Clip(
        notes: (0..<count).map { note($0 * ticksPerStep, channel: channel) },
        ticksPerBeat: ticksPerBeat, tempoBPM: 120, sourceTracks: [source], sourceFile: file)
}

private func song(_ clips: [Clip]) -> Song {
    Song(clips: clips, ticksPerBeat: ticksPerBeat, tempoBPM: 120, beatsPerBar: 4)
}

/// The planner, then the reading of it: the summary is never built any other way.
private func summarise(
    _ song: Song, firstPattern: Int = 1, firstTrack: Int = 1
) throws -> SegmentationSummary {
    let plan = try MIDIImport.planSong(
        song, firstPattern: firstPattern, firstTrack: firstTrack)
    return SegmentationSummary(song: song, plan: plan)
}

private func m6() throws -> (song: Song, plan: SongPlan) {
    let path = RepoData.projectFiles.appending(path: "m6-test-file.mid")
    let midi = try MusicalMIDI1File(data: Data(contentsOf: path))
    let song = try MIDIImport.readSongs([Source("m6-test-file.mid", midi)])
    return (song, try MIDIImport.planSong(song))
}

@Suite struct SegmentationTests {
    /// The whole point of the type: a preview that disagrees with the conversion is worse than no
    /// preview, so every figure is asserted against the planner's own rather than a second sum.
    @Test func everyFigureIsThePlannersOwn() throws {
        let (song, plan) = try m6()

        let summary = SegmentationSummary(song: song, plan: plan)

        #expect(summary.tracks.count == plan.tracks.count)
        for (track, planned) in zip(summary.tracks, plan.tracks) {
            #expect(track.deviceTrack == planned.track)
            #expect(track.sourceTrack == planned.sourceTrack)
            #expect(track.isDrum == planned.isDrum)
            #expect(track.noteCount == planned.notes.count)
            #expect(track.segments.map(\.pattern) == planned.patterns)
            #expect(track.segments.map(\.stepCount) == planned.placements.map(\.stepCount))
        }
    }

    @Test func thefixtureLaysFourSourceTracksOntoTheFourDeviceTracks() throws {
        let (song, plan) = try m6()

        let summary = SegmentationSummary(song: song, plan: plan)

        #expect(summary.tracks.map(\.deviceTrack) == [1, 2, 3, 4])
        #expect(summary.tracks.map(\.sourceTrack) == [3, 4, 5, 6])
        #expect(summary.unplaced.isEmpty)
    }

    /// Where the split falls, which is what a reader cannot get from a pattern count alone.
    @Test func arunPastTheDevicesMaximumSplitsAndTheNextPatternSaysWhereItResumes() throws {
        let (song, plan) = try m6()

        let summary = SegmentationSummary(song: song, plan: plan)

        let split = try #require(summary.tracks.first { $0.segments.count > 1 })
        #expect(split.deviceTrack == 4)
        #expect(split.segments.map(\.pattern) == [1, 2])
        #expect(split.segments.map(\.stepCount) == [64, 64])
        #expect(split.segments.map(\.firstStep) == [1, 65])
    }

    @Test func atrackThatFitsInOnePatternStartsAtStepOneAndStaysThere() throws {
        let summary = try summarise(song([clip(source: 1, notes: 8)]))

        #expect(summary.tracks.count == 1)
        #expect(summary.tracks[0].segments.map(\.firstStep) == [1])
        #expect(summary.tracks[0].droppedPatterns == 0)
    }

    /// The acceptance criterion: shown as such rather than omitted.
    @Test func asourceTrackWithNowhereToGoIsNamedRatherThanDropped() throws {
        let six = song((1...6).map { clip(source: $0, notes: 4, channel: $0 - 1) })

        let summary = try summarise(six)

        #expect(summary.tracks.map(\.sourceTrack) == [1, 2, 3, 4])
        #expect(summary.unplaced.map(\.sourceTrack) == [5, 6])
        #expect(summary.unplaced.map(\.noteCount) == [4, 4])
    }

    /// A source track carrying several channels becomes a device track apiece, so part of one can
    /// fail to fit while the rest of it lands -- and the part that did not must still be said.
    @Test func achannelOfAsourceTrackThatDoesNotFitIsStillReported() throws {
        let multi = song([
            clip(source: 1, notes: 1, channel: 0),
            clip(source: 2, notes: 1, channel: 1),
            clip(source: 3, notes: 1, channel: 2),
            clip(source: 3, notes: 1, channel: 3),
            clip(source: 3, notes: 1, channel: 4),
        ])

        let summary = try summarise(multi)

        #expect(summary.tracks.count == Constants.trackItemIDs.count)
        let short = try #require(summary.unplaced.first { $0.sourceTrack == 3 })
        #expect(short.droppedParts == 1)
        #expect(short.placedParts == 2)
        #expect(!short.isWhole)
    }

    @Test func asourceTrackDroppedWholeSaysSoRatherThanInParts() throws {
        let six = song((1...6).map { clip(source: $0, notes: 4, channel: $0 - 1) })

        let summary = try summarise(six)

        #expect(summary.unplaced.allSatisfy { $0.isWhole })
        #expect(summary.unplaced.map(\.placedParts) == [0, 0])
    }

    @Test func anunplacedSourceCarriesTheFileItWasReadFrom() throws {
        let six = song((1...6).map { clip(source: $0, notes: 4, channel: $0 - 1, file: "six.mid") })

        let summary = try summarise(six)

        #expect(summary.unplaced.map(\.sourceFile) == ["six.mid", "six.mid"])
    }

    /// A tail past the last pattern is dropped by the planner; the preview says how much.
    @Test func atailPastTheLastPatternIsCountedRatherThanHidden() throws {
        let past = Constants.patternsPerTrack * Constants.maxSteps * ticksPerStep
        let long = song([
            Clip(
                notes: [note(0), note(past)], ticksPerBeat: ticksPerBeat, tempoBPM: 120,
                sourceTracks: [1])
        ])

        let summary = try summarise(long)

        let track = try #require(summary.tracks.first)
        #expect(track.segments.count == Constants.patternsPerTrack)
        #expect(track.droppedPatterns > 0)
    }

    @Test func routingMovesWhereTheImportWouldLand() throws {
        let two = song([clip(source: 1, notes: 4), clip(source: 2, notes: 4, channel: 1)])

        let summary = try summarise(two, firstPattern: 3, firstTrack: 2)

        #expect(summary.tracks.map(\.deviceTrack) == [2, 3])
        #expect(summary.tracks.map { $0.segments.map(\.pattern) } == [[3], [3]])
    }

    @Test func thedrumTrackIsMarkedAsOne() throws {
        let kit = song([
            clip(source: 1, notes: 4, channel: MIDIImport.drumChannel),
            clip(source: 2, notes: 4, channel: 1),
        ])

        let summary = try summarise(kit)

        let drum = try #require(summary.tracks.first { $0.isDrum })
        #expect(drum.deviceTrack == 1)
        #expect(drum.sourceTrack == 1)
    }

    /// The planner counts what it dropped; the summary names which tracks they were.
    @Test func whatTheplannerCountsAsDroppedIsWhatTheSummaryNames() throws {
        let six = song((1...6).map { clip(source: $0, notes: 4, channel: $0 - 1) })
        let plan = try MIDIImport.planSong(six)

        let summary = SegmentationSummary(song: six, plan: plan)

        let counted = plan.diagnostics.first { $0.code == .tracksDropped }?.subjects
        #expect(summary.unplaced.count == counted)
    }
}
