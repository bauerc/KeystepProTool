import Foundation
import KSPKit
import KSPRun
import Testing

@testable import KSPApp

/// One slot of 960 ticks per pattern, so a run of two is half the axis each and the arithmetic is
/// readable in the assertions.
private let slotTicks = 960

private func slots(_ patterns: [Int]) -> [ArrangedSlot] {
    patterns.enumerated().map {
        ArrangedSlot(
            patternNumber: $0.element, startTick: $0.offset * slotTicks, lengthTicks: slotTicks)
    }
}

private func region(
    _ pattern: Int, at index: Int, length: Int = slotTicks, notes: Int = 4,
    marks: [ArrangedMark] = []
) -> ArrangedRegion {
    ArrangedRegion(
        patternNumber: pattern, startTick: index * slotTicks, spanTicks: slotTicks,
        lengthTicks: length, noteCount: notes, marks: marks)
}

private func arranged(_ patterns: [Int], regions: [Int: [ArrangedRegion]], drums: Set<Int> = [])
    -> ArrangementSummary
{
    ArrangementSummary(
        lengthTicks: patterns.count * slotTicks, ticksPerBeat: 480, slots: slots(patterns),
        tracks: (1...Constants.trackItemIDs.count).map {
            ArrangedLane(
                trackNumber: $0, isDrum: drums.contains($0), regions: regions[$0] ?? [])
        })
}

@Suite struct ArrangeLanesTests {
    @Test func aRunOfOnePatternFillsTheWholeAxis() {
        let lanes = ArrangeLanes(arranged([1], regions: [1: [region(1, at: 0)]]))

        #expect(lanes.boundaries.map(\.pattern) == [1])
        #expect(lanes.boundaries[0].x == 0)
        let drawn = lanes.lanes[0].regions[0]
        #expect(drawn.x == 0)
        #expect(drawn.width == AppLayout.axisWidth)
        #expect(drawn.x + drawn.width == AppLayout.axisWidth)
    }

    @Test func eachSlotTakesItsShareOfTheAxisInOrder() {
        let lanes = ArrangeLanes(
            arranged([2, 3], regions: [1: [region(2, at: 0), region(3, at: 1)]]))

        #expect(lanes.boundaries.map(\.pattern) == [2, 3])
        #expect(lanes.boundaries[1].x == AppLayout.axisWidth / 2)
        #expect(lanes.lanes[0].regions.map(\.x) == [0, AppLayout.axisWidth / 2])
        #expect(
            lanes.lanes[0].regions.map(\.width) == [
                AppLayout.axisWidth / 2, AppLayout.axisWidth / 2,
            ])
    }

    @Test func aShorterTrackDrawsShortOfItsSpan() {
        let lanes = ArrangeLanes(
            arranged(
                [1],
                regions: [1: [region(1, at: 0)], 2: [region(1, at: 0, length: slotTicks / 4)]]))

        let full = lanes.lanes[0].regions[0]
        let short = lanes.lanes[1].regions[0]
        #expect(full.width == AppLayout.axisWidth)
        #expect(short.width == AppLayout.axisWidth / 4)
        #expect(short.x == lanes.boundaries[0].x)
        #expect(short.x + short.width < full.x + full.width)
        #expect(short.detail.contains("loops back"))
    }

    @Test func aTrackPlayingNothingInASlotDrawsNoRegion() {
        let lanes = ArrangeLanes(
            arranged(
                [2, 3], regions: [1: [region(2, at: 0), region(3, at: 1)], 3: [region(2, at: 0)]]))

        #expect(lanes.lanes[0].regions.count == 2)
        #expect(lanes.lanes[2].regions.map(\.pattern) == [2])
        #expect(lanes.lanes[1].isEmpty)
        #expect(lanes.lanes[1].detail == "empty")
        #expect(lanes.lanes[2].readout == "02")
    }

    @Test func aHeldButSilentRegionIsDrawnAndSaysSo() {
        let lanes = ArrangeLanes(arranged([1], regions: [1: [region(1, at: 0, notes: 0)]]))

        let drawn = lanes.lanes[0].regions[0]
        #expect(drawn.isEmpty)
        #expect(drawn.width == AppLayout.axisWidth)
        #expect(drawn.detail.contains("every event switched off"))
    }

    @Test func aMarkSitsInsideItsRegionAtItsOwnPitch() {
        let marks = [
            ArrangedMark(tick: 0, durationTicks: 120, pitch: 60),
            ArrangedMark(tick: slotTicks / 2, durationTicks: 120, pitch: 72),
        ]
        let lanes = ArrangeLanes(
            arranged([1], regions: [1: [region(1, at: 0, marks: marks)]]))

        let drawn = lanes.lanes[0].regions[0]
        #expect(drawn.showsMarks)
        #expect(drawn.marks.count == 2)
        #expect(drawn.marks[0].x == 0)
        #expect(drawn.marks[1].x == AppLayout.axisWidth / 2)
        // Higher pitch, higher in the lane.
        #expect(drawn.marks[1].y < drawn.marks[0].y)
        #expect(drawn.marks.allSatisfy { $0.x + $0.width <= drawn.width })
    }

    @Test func aMarkRunningPastTheRegionIsHeldAtItsEdge() {
        let marks = [ArrangedMark(tick: slotTicks - 10, durationTicks: slotTicks, pitch: 60)]
        let lanes = ArrangeLanes(arranged([1], regions: [1: [region(1, at: 0, marks: marks)]]))

        let drawn = lanes.lanes[0].regions[0]
        #expect(drawn.marks[0].x + drawn.marks[0].width == drawn.width)
    }

    @Test func aRegionTooNarrowToReadDropsItsSketchAndItsNumber() {
        let count = Int((AppLayout.axisWidth / AppLayout.regionLabelMinimumWidth).rounded(.up)) + 1
        let patterns = (0..<count).map { $0 % AppLayout.columnCount + 1 }
        let regions = patterns.enumerated().map { region($0.element, at: $0.offset) }
        let lanes = ArrangeLanes(arranged(patterns, regions: [1: regions]))

        let drawn = lanes.lanes[0].regions[0]
        #expect(drawn.width < AppLayout.marksMinimumWidth)
        #expect(!drawn.showsMarks)
        #expect(!drawn.showsLabel)
        #expect(drawn.grid.isEmpty)
        #expect(drawn.width > 0)
        let slots = lanes.lanes[0].regions.map(\.slot)
        #expect(Set(slots).count == slots.count)
        #expect(Set(lanes.boundaries.map(\.slot)).count == lanes.boundaries.count)
    }

    @Test func aLaneFitsItsPitchWindowToWhatItPlays() {
        let marks = [48, 49, 50].enumerated().map {
            ArrangedMark(tick: $0.offset * 240, durationTicks: 120, pitch: $0.element)
        }
        let lanes = ArrangeLanes(arranged([1], regions: [1: [region(1, at: 0, marks: marks)]]))

        let lane = lanes.lanes[0]
        let ys = lane.regions[0].marks.map(\.y)
        #expect(ys[0] > ys[1])
        #expect(ys[1] > ys[2])
        #expect(ys[0] - ys[2] > AppLayout.markHeight)
        #expect(lane.range == "C2–D2")
        #expect(lane.middleC == nil)
        #expect(lanes.lanes[1].range == nil)
        #expect(lanes.lanes[1].middleC == nil)
    }

    /// On the run's own clock, so a note the export moved off the grid is seen to sit off it --
    /// `project_5.KeyStepPro`'s third kick lands at tick 4321, a beat past the bar it opens.
    @Test func aRegionIsRuledABeatApartOnTheRunsClock() {
        let lanes = ArrangeLanes(
            arranged([1, 2], regions: [1: [region(1, at: 0), region(2, at: 1)]]))
        let beat = AppLayout.axisWidth / 4

        #expect(lanes.lanes[0].regions[0].grid == [GridLine(x: beat, accented: false)])
        #expect(lanes.lanes[0].regions[1].grid == [GridLine(x: beat, accented: false)])
    }

    @Test func theLineOpeningEachBarIsAccented() {
        let bar = AppLayout.beatsPerBar * 480
        let held = ArrangedRegion(
            patternNumber: 1, startTick: 0, spanTicks: 2 * bar, lengthTicks: 2 * bar, noteCount: 4)
        let summary = ArrangementSummary(
            lengthTicks: 2 * bar, ticksPerBeat: 480,
            slots: [ArrangedSlot(patternNumber: 1, startTick: 0, lengthTicks: 2 * bar)],
            tracks: (1...Constants.trackItemIDs.count).map {
                ArrangedLane(trackNumber: $0, regions: $0 == 1 ? [held] : [])
            })

        let grid = ArrangeLanes(summary).lanes[0].regions[0].grid
        let beat = AppLayout.axisWidth / 8
        #expect(grid.map(\.x) == (1..<8).map { CGFloat($0) * beat })
        #expect(grid.map(\.accented) == [false, false, false, true, false, false, false])
    }

    @Test func aProjectHoldingNothingDrawsNoAxisAtAll() {
        let lanes = ArrangeLanes(
            ArrangementSummary(
                lengthTicks: 0, slots: [],
                tracks: (1...Constants.trackItemIDs.count).map { ArrangedLane(trackNumber: $0) }))

        #expect(lanes.boundaries.isEmpty)
        #expect(lanes.lanes.count == Constants.trackItemIDs.count)
        #expect(lanes.lanes.allSatisfy { $0.regions.isEmpty })
        #expect(lanes.header.hasPrefix("0 patterns"))
    }

    @Test func theHeaderCountsThePatternsAndTheBeats() {
        let lanes = ArrangeLanes(arranged([1, 2], regions: [1: [region(1, at: 0)]]))

        #expect(lanes.header == "2 patterns · 4 beats end to end")
    }

    @Test func theDrumLaneIsBadgedAndNamedAsTheDeviceNamesIt() {
        let lanes = ArrangeLanes(arranged([1], regions: [1: [region(1, at: 0)]], drums: [1]))

        #expect(lanes.lanes[0].isDrum)
        #expect(lanes.lanes[0].name == "Track 1")
        #expect(lanes.lanes[0].detail.contains("trigger"))
    }

    @Test func theAxisFitsTheStagedPaneAtTheSmallestWindow() {
        #expect(AppLayout.gridOrigin + AppLayout.axisWidth <= AppLayout.minimumCardContentWidth)
    }
}
