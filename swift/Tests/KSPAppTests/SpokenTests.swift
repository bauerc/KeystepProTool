import Foundation
import KSPKit
import KSPRun
import Testing

@testable import KSPApp

private func segment(
    _ pattern: Int, steps: Int, from first: Int, notes: Int = 0, dropped: Int = 0,
    held: [SegmentNote] = []
) -> Segment {
    Segment(
        pattern: pattern, stepCount: steps, firstStep: first, noteCount: notes,
        mostNotesOnAStep: 1, droppedNotes: dropped, notes: held)
}

@Suite struct SpokenTests {
    @Test func aTooltipsSeparatorsArePauses() {
        #expect(
            aloud("Pattern 4 — 76 notes held · Chain place 2")
                == "Pattern 4, 76 notes held, Chain place 2")
    }

    @Test func aDashBetweenFiguresIsARangeAndOneInsideAWordIsLeftAlone() {
        #expect(aloud("patterns 1-2") == "patterns 1 to 2")
        #expect(aloud("C2–D2") == "C2 to D2")
        #expect(aloud("fresh-note velocity") == "fresh-note velocity")
    }

    @Test func aPatternMapRowIsSpokenAsItsModeItsPatternAndItsCounts() {
        let grid = PatternGrid(
            syntheticSummary(drumTracks: [1], notes: [1: [1: (held: 40, enabled: 32)]]))

        #expect(grid.rows[0].spoken == "drum, on pattern 1, 1 pattern, 32 triggers switched on")
        #expect(grid.rows[1].spoken == "empty")
    }

    @Test func aChainIsSpokenInPlayOrder() {
        let grid = PatternGrid(
            syntheticSummary(chains: [2: [3, 1, 7]], notes: [2: [3: (held: 4, enabled: 4)]]))

        #expect(
            grid.rows[1].spoken
                == "on pattern 3, 1 pattern, 4 notes switched on, chain 3 then 1 then 7")
    }

    @Test func aSlotCellIsSpokenWithoutTheNameItIsLabelledWith() {
        let grid = PatternGrid(
            syntheticSummary(chains: [1: [1, 2, 1]], notes: [1: [1: (held: 4, enabled: 4)]]))
        let cells = grid.rows[0].cells

        #expect(cells[0].spoken == "4 notes held, 4 switched on, 16 steps, Chain places 1 and 3")
        #expect(cells[1].spoken == "empty, Chain place 2")
        #expect(cells[2].spoken == "empty")
    }

    @Test func aTickIsSpokenAsWhatItDoesToTheExport() {
        #expect(GridSelection.Tick.on.spoken == "exported")
        #expect(GridSelection.Tick.off.spoken == "not exported")
        #expect(GridSelection.Tick.mixed.spoken == "partly exported")
    }

    @Test func aSourceTrackIsSpokenAsOneLine() {
        let song = syntheticSong(tracks: [
            sourceTrack(1, name: "Piano", noteCount: 128, bars: 4),
            sourceTrack(2, channels: [1, 2]),
            sourceTrack(3, noteCount: 0),
        ])
        let rows = SourceTrackList(
            song, drums: gmDrums, selection: SourceTrackSelection(song)
        ).rows

        #expect(rows[0].spoken == "Source track 1, Piano, channel 1, 128 notes, 4 bars")
        #expect(rows[1].spoken == "Source track 2, channels 1 and 2, 8 notes, 2 bars")
        #expect(rows[2].spoken == "Source track 3, no notes")
    }

    @Test func anImportRowAndItsCellsSayTheirRangesAsRanges() {
        let track = SegmentedTrack(
            deviceTrack: 1, sourceTrack: 3, noteCount: 40,
            segments: [segment(1, steps: 64, from: 1), segment(2, steps: 32, from: 65)])
        let grid = SegmentationGrid(SegmentationSummary(tracks: [track]))

        #expect(grid.rows[0].spoken == "Source track 3, 40 notes, patterns 1 to 2, 96 steps in all")
        #expect(grid.rows[0].cells[1].spoken == "32 steps, steps 65 to 96 of the run")
        #expect(grid.rows[0].cells[2].spoken == "empty")
        #expect(grid.rows[1].spoken == "empty")
    }

    @Test func aLaneAndItsRegionsAreSpokenAsTheirTooltipsSayThem() {
        let summary = ArrangementSummary(
            lengthTicks: 1920, ticksPerBeat: 480,
            slots: [0, 1].map {
                ArrangedSlot(patternNumber: $0 + 1, startTick: $0 * 960, lengthTicks: 960)
            },
            tracks: (1...Constants.trackItemIDs.count).map { track in
                ArrangedLane(
                    trackNumber: track, isDrum: track == 1,
                    regions: track != 1
                        ? []
                        : [0, 1].map {
                            ArrangedRegion(
                                patternNumber: $0 + 1, startTick: $0 * 960, spanTicks: 960,
                                lengthTicks: 960, noteCount: 4, marks: [])
                        })
            })
        let lane = ArrangeLanes(summary).lanes[0]

        #expect(lane.spoken == "drum, 8 triggers, patterns 1 to 2, 4 beats in all")
        #expect(lane.regions[1].spoken == "4 events, from beat 3")
    }

    @Test func aNoteShapeSaysItsRangeAndEveryPatternItsBracketsName() {
        let track = SegmentedTrack(
            deviceTrack: 1, noteCount: 2,
            segments: [
                segment(1, steps: 64, from: 1, notes: 1, held: [SegmentNote(step: 1, pitch: 60)]),
                segment(2, steps: 63, from: 65, notes: 1, held: [SegmentNote(step: 1, pitch: 62)]),
            ])

        #expect(
            NoteShape(track, stepsAcross: 127).spoken
                == "2 notes, patterns 1 to 2, 127 steps in all, pitches C3 to D3, "
                + "pattern 1, 64 steps, pattern 2, 63 steps")
    }

    @Test func aLimitMeterIsSpokenAsItsFigureItsStatusAndItsSite() throws {
        let pool = Constants.poolCapacity
        let limits = Limits(
            SegmentationSummary(tracks: [
                SegmentedTrack(
                    deviceTrack: 1, sourceTrack: 1, noteCount: pool,
                    segments: [segment(1, steps: 48, from: 1, notes: pool, dropped: 3)])
            ]))
        let spoken = Dictionary(uniqueKeysWithValues: limits.gauges.map { ($0.name, $0.spoken) })

        #expect(spoken["Tracks"] == "1 of 4")
        #expect(spoken["Steps per pattern"] == "48 of 64, close to the limit, Track 1, pattern 1")
        #expect(
            spoken["Notes per pattern"] == "\(pool) of \(pool), 3 notes over, Track 1, pattern 1")
    }
}
