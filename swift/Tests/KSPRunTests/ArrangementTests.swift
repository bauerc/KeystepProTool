import Foundation
import KSPKit
import KSPMIDI
import Testing

@testable import KSPRun

/// Asserted as ticks, because a preview that rounds is a preview that drifts. `project_9` fills
/// patterns 2 and 3 of track 1 and pattern 2 alone of track 3, which is the unequal case.
@Suite struct ArrangementTests {
    static func options(_ name: String) -> ExportRunner.Options {
        ExportRunner.Options(
            path: RepoData.projectFiles.appending(path: name), configPath: noPersonalConfig)
    }

    static func arrange(_ name: String) throws -> ArrangementSummary {
        let outcome = ArrangementRunner.run(options(name))
        #expect(outcome.message == nil)
        return try #require(outcome.summary)
    }

    static func lane(_ summary: ArrangementSummary, _ track: Int) throws -> ArrangedLane {
        try #require(summary.tracks.first { $0.trackNumber == track })
    }

    @Test func itLaysEverySlotEndToEndAlongTheRun() throws {
        let summary = try Self.arrange("project_9.KeyStepPro")

        #expect(summary.lengthTicks == 9600)
        #expect(summary.ticksPerBeat == 480)
        #expect(summary.slots.map(\.patternNumber) == [2, 3])
        #expect(summary.slots.map(\.startTick) == [0, 1920])
        #expect(summary.slots.map(\.lengthTicks) == [1920, 7680])
        // The slots tile the run: no overlap, and nothing left over at the end.
        #expect(summary.slots.reduce(0) { $0 + $1.lengthTicks } == summary.lengthTicks)
    }

    @Test func aTrackPlayingFewerPatternsLeavesTheSlotEmptyRatherThanStretching() throws {
        let summary = try Self.arrange("project_9.KeyStepPro")

        let first = try Self.lane(summary, 1)
        #expect(first.patterns == [2, 3])
        #expect(first.regions.map(\.startTick) == [0, 1920])
        #expect(first.regions.map(\.lengthTicks) == [1920, 7680])

        // The gap: track 3 stops after pattern 2, and no region is invented to fill slot 3.
        let third = try Self.lane(summary, 3)
        #expect(third.patterns == [2])
        #expect(third.regions.map(\.startTick) == [0])
        #expect(third.regions.map(\.lengthTicks) == [1920])
        #expect(!third.regions.contains { $0.patternNumber == 3 })
    }

    @Test func itDrawsAllFourDeviceTracksWhateverTheProjectFills() throws {
        let summary = try Self.arrange("project_9.KeyStepPro")

        #expect(summary.tracks.map(\.trackNumber) == [1, 2, 3, 4])
        #expect(try Self.lane(summary, 2).isEmpty)
        #expect(try Self.lane(summary, 4).isEmpty)
        #expect(try Self.lane(summary, 1).isDrum)
        #expect(try !Self.lane(summary, 3).isDrum)
        #expect(try Self.lane(summary, 1).name == "Track 1 (drum)")
    }

    @Test func itCarriesTheExportsOwnUnequalLengthsFinding() throws {
        let outcome = ArrangementRunner.run(Self.options("project_9.KeyStepPro"))

        #expect(outcome.diagnostics.entries.contains { $0.code == .trackLengthsDiffer })
        #expect(
            outcome.summary?.diagnostics.entries.contains { $0.code == .trackLengthsDiffer } == true
        )
    }

    @Test func onePatternAcrossTwoTracksIsOneSlotBothFill() throws {
        let summary = try Self.arrange("project_5.KeyStepPro")

        #expect(summary.lengthTicks == 7680)
        #expect(summary.slots.map(\.patternNumber) == [1])
        #expect(summary.slots[0].lengthTicks == 7680)
        for track in [1, 3] {
            let lane = try Self.lane(summary, track)
            #expect(lane.regions.count == 1)
            #expect(lane.regions[0].lengthTicks == lane.regions[0].spanTicks)
            #expect(lane.regions[0].gapTicks == 0)
        }
        #expect(try Self.lane(summary, 1).noteCount == 4)
        #expect(try Self.lane(summary, 3).noteCount == 28)
    }

    @Test func aProjectHoldingNothingLaysOutNothing() throws {
        let summary = try Self.arrange("user_empty_project.KeyStepPro")

        #expect(summary.isEmpty)
        #expect(summary.lengthTicks == 0)
        #expect(summary.tracks.count == Constants.trackItemIDs.count)
        #expect(summary.tracks.allSatisfy { $0.isEmpty })
    }

    @Test func aMarkPerRenderedEventInTheRegionsOwnTicks() throws {
        let summary = try Self.arrange("project_5.KeyStepPro")
        let region = try #require(Self.lane(summary, 3).regions.first)

        #expect(region.marks.count == region.noteCount)
        #expect(region.marks.allSatisfy { $0.tick >= 0 && $0.tick < region.spanTicks })
        // The pitches `tests/fixtures/project_5.expected.json` transcribes, which the device shows
        // as C2, C#2 and D2 -- 60 is C3.
        #expect(Set(region.marks.map(\.pitch)).sorted() == [48, 49, 50])
        #expect(region.marks.allSatisfy { $0.durationTicks > 0 })
    }

    @Test func repeatingTheRunRepeatsEverySlot() throws {
        var options = Self.options("project_9.KeyStepPro")
        options.repeatCount = 2
        let summary = try #require(ArrangementRunner.run(options).summary)

        #expect(summary.lengthTicks == 19200)
        #expect(summary.slots.map(\.patternNumber) == [2, 3, 2, 3])
        #expect(summary.slots.map(\.startTick) == [0, 1920, 9600, 11520])
        #expect(try Self.lane(summary, 1).regions.count == 4)
        // The second pass of a Pattern is the same region, laid down a run further along.
        #expect(try Self.lane(summary, 3).regions.map(\.startTick) == [0, 9600])
    }

    @Test func anUntickedSlotLeavesThePreviewAsItLeavesTheFile() throws {
        var options = Self.options("project_9.KeyStepPro")
        options.cells = [1: [2], 3: [2]]
        let summary = try #require(ArrangementRunner.run(options).summary)

        #expect(summary.slots.map(\.patternNumber) == [2])
        #expect(summary.lengthTicks == 1920)
        #expect(try Self.lane(summary, 1).patterns == [2])
    }

    @Test func aSplitRunHasNoSharedTimelineToShow() throws {
        var options = Self.options("project_9.KeyStepPro")
        options.split = true
        let outcome = ArrangementRunner.run(options)

        #expect(outcome.summary == nil)
        #expect(outcome.message?.contains("one file per pattern") == true)
    }

    @Test func anUnreadableFileComesBackAsAMessageRatherThanThrowing() throws {
        let outcome = ArrangementRunner.run(Self.options("test_file.mid"))

        #expect(outcome.summary == nil)
        #expect(outcome.message != nil)
    }

    /// The corpus gives every track the same length in the slots it fills, so the shorter-region
    /// case is built from renderings and arranged for real rather than from invented geometry.
    @Test func aShorterTrackKeepsItsOwnLengthInsideTheSharedSpan() throws {
        let long = Rendering(
            trackNumber: 1, kind: .seq, patternNumber: 1,
            notes: [
                RenderedNote(tick: 0, durationTicks: 120, pitch: 60, velocity: 100, channel: 0)
            ],
            lengthTicks: 3840)
        let short = Rendering(
            trackNumber: 2, kind: .seq, patternNumber: 1,
            notes: [
                RenderedNote(tick: 0, durationTicks: 120, pitch: 64, velocity: 100, channel: 1)
            ],
            lengthTicks: 960)
        let renderings = [long, short]
        let summary = ArrangementSummary(
            renderings: renderings,
            arrangement: try MIDIExport.arrange(renderings), ticksPerBeat: 480)

        // The span is the longest any track gives the slot, so both start pattern 1 together.
        #expect(summary.slots.map(\.lengthTicks) == [3840])
        #expect(try Self.lane(summary, 1).regions[0].lengthTicks == 3840)
        #expect(try Self.lane(summary, 1).regions[0].gapTicks == 0)
        #expect(try Self.lane(summary, 2).regions[0].spanTicks == 3840)
        #expect(try Self.lane(summary, 2).regions[0].lengthTicks == 960)
        #expect(try Self.lane(summary, 2).regions[0].gapTicks == 2880)
    }

    /// Held but silent is not the same as absent: one draws a region with nothing in it, the other
    /// draws no region at all.
    @Test func aRenderedPatternWithEveryEventOffKeepsItsRegion() throws {
        let silent = Rendering(
            trackNumber: 1, kind: .seq, patternNumber: 4, notes: [], lengthTicks: 1920)
        let summary = ArrangementSummary(
            renderings: [silent], arrangement: try MIDIExport.arrange([silent]), ticksPerBeat: 480)

        let lane = try Self.lane(summary, 1)
        #expect(lane.regions.count == 1)
        #expect(lane.regions[0].isEmpty)
        #expect(lane.regions[0].lengthTicks == 1920)
        #expect(lane.regions[0].marks.isEmpty)
        #expect(try Self.lane(summary, 2).regions.isEmpty)
    }
}
