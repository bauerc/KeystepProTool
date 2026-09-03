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
        #expect(drawn.spanWidth == AppLayout.axisWidth)
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

    /// The load-bearing case: a track playing a shorter Pattern keeps its own width inside the
    /// span, so the slot is not filled and the gap is what the eye reads.
    @Test func aShorterTrackDrawsShortOfItsSpan() {
        let lanes = ArrangeLanes(
            arranged(
                [1],
                regions: [1: [region(1, at: 0)], 2: [region(1, at: 0, length: slotTicks / 4)]]))

        let full = lanes.lanes[0].regions[0]
        let short = lanes.lanes[1].regions[0]
        #expect(full.width == AppLayout.axisWidth)
        #expect(short.width == AppLayout.axisWidth / 4)
        #expect(short.spanWidth == AppLayout.axisWidth)
        #expect(short.width < short.spanWidth)
        #expect(short.detail.contains("loops back"))
    }

    /// A track that plays no Pattern in a slot draws nothing there, rather than an empty block.
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

    /// A note whose gate runs past the last step is held inside the region rather than drawn over
    /// the next one.
    @Test func aMarkRunningPastTheRegionIsHeldAtItsEdge() {
        let marks = [ArrangedMark(tick: slotTicks - 10, durationTicks: slotTicks, pitch: 60)]
        let lanes = ArrangeLanes(arranged([1], regions: [1: [region(1, at: 0, marks: marks)]]))

        let drawn = lanes.lanes[0].regions[0]
        #expect(drawn.marks[0].x + drawn.marks[0].width == drawn.width)
    }

    @Test func aRegionTooNarrowToReadDropsItsSketchAndItsNumber() {
        // Sixty-four slots on one axis leaves each under ten points.
        let patterns = Array(1...16) + Array(1...16) + Array(1...16) + Array(1...16)
        let regions = patterns.enumerated().map { region($0.element, at: $0.offset) }
        let lanes = ArrangeLanes(arranged(patterns, regions: [1: regions]))

        let drawn = lanes.lanes[0].regions[0]
        #expect(drawn.width < AppLayout.marksMinimumWidth)
        #expect(!drawn.showsMarks)
        #expect(!drawn.showsLabel)
        // The block still carries the geometry, which is what the view is for.
        #expect(drawn.width > 0)
    }

    @Test func pitchIsClampedIntoTheWindowRatherThanScaledToTheFile() {
        #expect(
            AppLayout.y(ofPitch: 0) == AppLayout.y(ofPitch: AppLayout.markPitchWindow.lowerBound))
        #expect(
            AppLayout.y(ofPitch: 127) == AppLayout.y(ofPitch: AppLayout.markPitchWindow.upperBound))
        #expect(AppLayout.y(ofPitch: AppLayout.markPitchWindow.upperBound) == 0)
        #expect(
            AppLayout.y(ofPitch: AppLayout.markPitchWindow.lowerBound)
                == AppLayout.laneHeight - AppLayout.markHeight)
    }

    @Test func aProjectHoldingNothingDrawsNoAxisAtAll() {
        let lanes = ArrangeLanes(
            ArrangementSummary(
                lengthTicks: 0, slots: [],
                tracks: (1...Constants.trackItemIDs.count).map { ArrangedLane(trackNumber: $0) }))

        #expect(lanes.isEmpty)
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

    /// The pane scrolls vertically only, so an axis wider than the narrowest pane would be clipped
    /// with no way for the user to resize out of it.
    @Test func theAxisFitsTheStagedPaneAtTheSmallestWindow() {
        #expect(AppLayout.gridOrigin + AppLayout.axisWidth <= AppLayout.minimumContentWidth)
        // Drawn under the map, on the map's own origin, so the two axes line up column for column.
        #expect(AppLayout.gridOrigin + AppLayout.axisWidth == AppLayout.gridWidth)
    }
}
