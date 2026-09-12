import Foundation
import KSPKit
import KSPRun
import Testing

@testable import KSPApp

private func note(_ step: Int, _ pitch: Int, length: Double = 1) -> SegmentNote {
    SegmentNote(step: step, pitch: pitch, length: length)
}

private func run(_ patterns: [(steps: Int, notes: [SegmentNote])], track: Int = 1)
    -> SegmentedTrack
{
    var first = 1
    var segments: [Segment] = []
    for (index, entry) in patterns.enumerated() {
        segments.append(
            Segment(
                pattern: index + 1, stepCount: entry.steps, firstStep: first,
                noteCount: entry.notes.count, notes: entry.notes))
        first += entry.steps
    }
    return SegmentedTrack(
        deviceTrack: track, noteCount: segments.reduce(0) { $0 + $1.noteCount },
        segments: segments)
}

@Suite struct PitchWindowTests {
    @Test func aWideRangeIsFittedToExactlyWhatItHolds() {
        let window = PitchWindow([36, 60, 72])

        #expect(window.low == 36)
        #expect(window.high == 72)
    }

    @Test func aNarrowRangeIsWidenedToAnOctaveAroundItself() {
        let window = PitchWindow([48, 50])

        #expect(window.low == 43)
        #expect(window.high == 55)
        #expect(window.high - window.low == AppLayout.pitchWindowMinimumSpan)
    }

    @Test func oneHeldPitchSitsMidway() {
        #expect(PitchWindow([36]).y(ofPitch: 36, in: 56, markHeight: 2) == 27)
    }

    @Test func highIsAtTheTopLowAtTheBottomAndPastEitherIsHeldThere() {
        let window = PitchWindow([36, 72])

        #expect(window.y(ofPitch: 72, in: 50, markHeight: 2) == 0)
        #expect(window.y(ofPitch: 36, in: 50, markHeight: 2) == 48)
        #expect(window.y(ofPitch: 127, in: 50, markHeight: 2) == 0)
        #expect(window.y(ofPitch: 0, in: 50, markHeight: 2) == 48)
    }

    @Test func theC3LineRunsOnlyWhereTheWindowReachesMiddleC() {
        let reaching = PitchWindow([48, 72])

        #expect(reaching.middleC(in: 50, markHeight: 2) == 25)
        #expect(PitchWindow([36, 38]).middleC(in: 50, markHeight: 2) == nil)
    }

    /// C3 is MIDI 60, as the device shows it -- not C4.
    @Test func aRangeIsNamedInTheDevicesNumerals() {
        #expect(pitchRange([48, 60, 84]) == "C2–C5")
        #expect(pitchRange([60]) == "C3")
        #expect(pitchRange([]) == nil)
    }

    @Test func gridLinesThinOutByTheirOwnGroupRatherThanCrowd() {
        let spacing = AppLayout.gridLineMinimumSpacing

        #expect(AppLayout.gridStride(unitWidth: spacing, group: 4) == 1)
        #expect(AppLayout.gridStride(unitWidth: spacing / 2, group: 4) == 4)
        #expect(AppLayout.gridStride(unitWidth: spacing / 10, group: 4) == 16)
        #expect(AppLayout.gridStride(unitWidth: spacing / 2, group: 3) == 3)
        #expect(AppLayout.gridStride(unitWidth: 0, group: 4) == 0)
    }
}

@Suite struct NoteShapeTests {
    @Test func aOnePatternRunFillsTheAxisWithEachNoteOnItsStep() {
        let shape = NoteShape(
            run([(16, [note(1, 60), note(5, 48, length: 2), note(12, 84)])]), stepsAcross: 16)
        let step = AppLayout.axisWidth / 16

        let region = shape.regions[0]
        #expect(region.x == 0)
        #expect(region.width == AppLayout.axisWidth)
        #expect(region.marks.map(\.x) == [0, 4 * step, 11 * step])
        #expect(region.marks[1].width == 2 * step)
        #expect(region.marks[2].y < region.marks[0].y)
        #expect(region.marks[0].y < region.marks[1].y)
        #expect(shape.range == "C2–C5")
    }

    @Test func everyStepIsRuledAndEveryBeatAccented() {
        let shape = NoteShape(run([(16, [note(1, 60)])]), stepsAcross: 16)
        let step = AppLayout.axisWidth / 16

        let grid = shape.regions[0].grid
        let accents = grid.filter { $0.accented }.map(\.x)
        #expect(grid.map(\.x) == (1..<16).map { CGFloat($0) * step })
        #expect(accents == [4 * step, 8 * step, 12 * step])
    }

    /// `m6-test-file.mid`'s 127-step track: two Patterns, each counting its beats and its notes
    /// from its own first step, as the device will.
    @Test func aSplitRunIsARegionPerPatternEachCountedFromItsOwnStart() {
        let shape = NoteShape(
            run([(64, [note(1, 60)]), (63, [note(1, 62)])]), stepsAcross: 127)
        let step = AppLayout.axisWidth / 127

        #expect(shape.regions.map(\.pattern) == [1, 2])
        #expect(shape.regions[1].x == 64 * step)
        #expect(shape.regions[1].marks[0].x == 0)
        #expect(shape.regions[1].grid.first?.x == 4 * step)
        #expect(
            shape.regions.map(\.bracket) == ["pattern 1 · 64 steps", "pattern 2 · 63 steps"])
        #expect(shape.regions.allSatisfy { $0.showsBracket })
    }

    @Test func aNoteHeldPastItsPatternsLastStepStopsThere() {
        let shape = NoteShape(run([(16, [note(15, 60, length: 8)]), (16, [])]), stepsAcross: 32)

        let region = shape.regions[0]
        #expect(region.marks[0].x + region.marks[0].width == region.width)
        #expect(shape.regions[1].isEmpty)
    }

    @Test func everyShapeOfAPlanSharesOneStepAxis() {
        let summary = SegmentationSummary(tracks: [
            run([(32, [note(1, 60)])], track: 1), run([(16, [note(1, 60)])], track: 2),
            SegmentedTrack(deviceTrack: 3),
        ])

        let shapes = NoteShape.shapes(summary)

        #expect(shapes.map(\.track) == [1, 2])
        #expect(shapes[0].regions[0].width == AppLayout.axisWidth)
        #expect(shapes[1].regions[0].width == AppLayout.axisWidth / 2)
    }

    @Test func aBracketTooNarrowForItsWordsIsDrawnBare() {
        let shape = NoteShape(run([(16, [note(1, 60)])]), stepsAcross: 1024)

        #expect(shape.regions[0].width < AppLayout.bracketLabelMinimumWidth)
        #expect(!shape.regions[0].showsBracket)
        #expect(shape.regions[0].bracket == "pattern 1 · 16 steps")
    }

    @Test func aRunTooLongToRuleEveryStepThinsOutByFours() {
        let shape = NoteShape(run([(64, [])]), stepsAcross: 1024)
        let step = AppLayout.axisWidth / 1024

        let grid = shape.regions[0].grid
        #expect(grid.map(\.x) == [16 * step, 32 * step, 48 * step])
        #expect(grid.allSatisfy { !$0.accented })
    }

    @Test func middleCIsLabelledFirstAndACrowdingLabelIsDropped() {
        let shape = NoteShape(
            run([(16, [note(1, 36), note(2, 60), note(3, 61)])]), stepsAcross: 16)

        #expect(shape.labels.map(\.text) == ["C3", "C1"])
        #expect(shape.range == "C1–C#3")
        #expect(
            shape.labels.allSatisfy {
                $0.y >= 0 && $0.y <= AppLayout.laneHeight - AppLayout.pitchLabelHeight
            })
    }

    @Test func aShapeNowhereNearMiddleCRulesNoLineThere() {
        let shape = NoteShape(run([(16, [note(1, 36), note(2, 48)])]), stepsAcross: 16)

        #expect(shape.middleC == nil)
        #expect(shape.labels.map(\.text) == ["C2", "C1"])
    }
}
