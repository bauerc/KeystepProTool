import Foundation
import KSPKit
import KSPRun
import Testing

@testable import KSPApp

private func segmented(
    _ deviceTrack: Int, source: Int? = nil, steps: [Int], firstPattern: Int = 1
) -> SegmentedTrack {
    var step = 1
    var segments: [Segment] = []
    for (offset, count) in steps.enumerated() {
        segments.append(
            Segment(pattern: firstPattern + offset, stepCount: count, firstStep: step))
        step += count
    }
    return SegmentedTrack(
        deviceTrack: deviceTrack, sourceTrack: source, noteCount: 16, segments: segments)
}

/// Four steps to the beat in four four: the bar that divides 64, so the automatic cut lands on one.
private func summary(_ tracks: [SegmentedTrack], stepsPerBar: Int = 16) -> SegmentationSummary {
    SegmentationSummary(tracks: tracks, stepsPerBar: stepsPerBar)
}

private func lane(_ summary: SegmentationSummary, source: Int) throws -> SegmentLane {
    try #require(SegmentLane(source: source, summary: summary))
}

@Suite struct SegmentBoundariesTests {
    /// The whole of "untouched, the result matches automatic splitting exactly": no entry, no
    /// spec, and the run is the one that ran before.
    @Test func untouchedItNamesNoSegmentation() {
        #expect(SegmentBoundaries().spec == nil)
        #expect(SegmentBoundaries().isEdited == false)
    }

    /// A spec entry replaces the automatic cut for its track outright, so the first drag has to
    /// take down every boundary, not only the one under the hand.
    @Test func thefirstDragSeedsEveryBoundaryTheTrackAlreadyHad() {
        var boundaries = SegmentBoundaries()

        boundaries.seed(source: 2, bars: [5, 9])
        boundaries.move(source: 2, handle: 0, to: 4)

        #expect(boundaries.spec == "2:4,2:9")
    }

    @Test func seedingATrackAlreadySeededLeavesTheDraggedBarsAlone() {
        var boundaries = SegmentBoundaries()

        boundaries.seed(source: 2, bars: [5, 9])
        boundaries.move(source: 2, handle: 1, to: 12)
        boundaries.seed(source: 2, bars: [5, 9])

        #expect(boundaries.spec == "2:5,2:12")
    }

    /// A track with one pattern has no boundary to move, so nothing about it reaches the spec.
    @Test func atrackWithNoBoundaryIsNeverSeeded() {
        var boundaries = SegmentBoundaries()

        boundaries.seed(source: 3, bars: [])

        #expect(boundaries.spec == nil)
    }

    @Test func severalTracksAreNamedInSourceOrder() {
        var boundaries = SegmentBoundaries()

        boundaries.seed(source: 3, bars: [3])
        boundaries.seed(source: 2, bars: [5, 9])

        #expect(boundaries.spec == "2:5,2:9,3:3")
    }

    @Test func resetReturnsToTheAutomaticSplit() {
        var boundaries = SegmentBoundaries()
        boundaries.seed(source: 2, bars: [5])
        boundaries.move(source: 2, handle: 0, to: 7)

        boundaries.reset()

        #expect(boundaries.spec == nil)
        #expect(boundaries.isEdited == false)
    }

    @Test func movingAhandleTheTrackHasNotGotChangesNothing() {
        var boundaries = SegmentBoundaries()
        boundaries.seed(source: 2, bars: [5])

        boundaries.move(source: 2, handle: 4, to: 7)
        boundaries.move(source: 9, handle: 0, to: 7)

        #expect(boundaries.spec == "2:5")
    }
}

@Suite struct SegmentLaneTests {
    @Test func asourceTrackThePlanNeverPlacedHasNoLane() {
        let placed = summary([segmented(1, source: 2, steps: [64])])

        #expect(SegmentLane(source: 7, summary: placed) == nil)
    }

    @Test func alaneIsAsManyBarsAsTheRunIsLong() throws {
        let subject = try lane(summary([segmented(1, source: 2, steps: [64, 32])]), source: 2)

        #expect(subject.barCount == 6)
        #expect(subject.sourceTrack == 2)
    }

    /// The boundaries are the planner's own cuts, read back as the bars they fall at.
    @Test func ahandleSitsOnEveryCutTheplannerMade() throws {
        let subject = try lane(summary([segmented(1, source: 2, steps: [64, 64, 32])]), source: 2)

        #expect(subject.handles.map(\.bar) == [5, 9])
        #expect(subject.handles.map(\.index) == [0, 1])
    }

    @Test func asinglePatternRunHasNothingToDrag() throws {
        let subject = try lane(summary([segmented(1, source: 2, steps: [48])]), source: 2)

        #expect(subject.handles.isEmpty)
        #expect(subject.regions.count == 1)
    }

    /// The lane's whole claim: a longer segment is a wider region, and the regions tile it.
    @Test func regionsTileTheLaneInProportionToTheirLength() throws {
        let subject = try lane(summary([segmented(1, source: 2, steps: [64, 32])]), source: 2)

        #expect(subject.regions.count == 2)
        #expect(subject.regions[0].x == 0)
        #expect(subject.regions[0].width == AppLayout.laneWidth * 4 / 6)
        #expect(subject.regions[1].x == subject.regions[0].width)
        let filled = subject.regions.reduce(0) { $0 + $1.width }
        #expect(abs(filled - AppLayout.laneWidth) < 0.001)
    }

    @Test func ahandleSitsWhereItsRegionBegins() throws {
        let subject = try lane(summary([segmented(1, source: 2, steps: [64, 32])]), source: 2)

        #expect(subject.handles.count == 1)
        #expect(subject.handles[0].x == subject.regions[1].x)
    }

    @Test func aregionSaysTheBarsItCovers() throws {
        let subject = try lane(summary([segmented(1, source: 2, steps: [64, 16])]), source: 2)

        #expect(subject.regions[0].label == "bars 1-4")
        #expect(subject.regions[1].label == "bar 5")
    }

    /// One source track becomes one device track per channel, and the same bars cut every part,
    /// so the parts share a lane rather than getting one each.
    @Test func asourceTrackOnSeveralDeviceTracksGetsOneLane() throws {
        let subject = try lane(
            summary([
                segmented(1, source: 2, steps: [64]),
                segmented(2, source: 2, steps: [64, 32]),
            ]), source: 2)

        #expect(subject.barCount == 6)
        #expect(subject.handles.map(\.bar) == [5])
    }

    /// Which pattern a region fills is only unambiguous where the source made one device track.
    @Test func aregionNamesItsPatternOnlyWhereTheSourceMadeOneTrack() throws {
        let one = try lane(summary([segmented(1, source: 2, steps: [64, 32])]), source: 2)
        let two = try lane(
            summary([
                segmented(1, source: 2, steps: [64, 32]),
                segmented(2, source: 2, steps: [64, 32]),
            ]), source: 2)

        #expect(one.regions[0].detail.contains("Pattern 1"))
        #expect(two.regions[0].detail.contains("Pattern") == false)
    }

    @Test func adragSnapsToTheNearestBar() throws {
        let subject = try lane(summary([segmented(1, source: 2, steps: [64, 64])]), source: 2)
        let bar = AppLayout.laneWidth / 8

        #expect(subject.bar(forHandle: 0, atX: bar * 2 + 1) == 3)
        #expect(subject.bar(forHandle: 0, atX: bar * 2 - 1) == 3)
        #expect(subject.bar(forHandle: 0, atX: bar * 6 + 2) == 7)
    }

    /// The geometry says a handle cannot pass its neighbours; the planner is left to say the two
    /// things geometry cannot -- past the step limit, and past the free patterns.
    @Test func ahandleIsHeldBetweenItsNeighbours() throws {
        let subject = try lane(summary([segmented(1, source: 2, steps: [32, 32, 32])]), source: 2)

        #expect(subject.handles.map(\.bar) == [3, 5])
        #expect(subject.bar(forHandle: 1, atX: 0) == 4)
        #expect(subject.bar(forHandle: 0, atX: AppLayout.laneWidth) == 4)
    }

    @Test func ahandleIsHeldInsideTheTrack() throws {
        let subject = try lane(summary([segmented(1, source: 2, steps: [64, 32])]), source: 2)

        #expect(subject.bar(forHandle: 0, atX: -400) == 2)
        #expect(subject.bar(forHandle: 0, atX: AppLayout.laneWidth * 4) == 6)
    }

    /// The automatic split cuts every 64 steps, which is a whole number of bars only where the
    /// bar divides 64. In three four it does not, so the cut is reported at the bar it lands in.
    @Test func acutFallingMidBarIsReportedAtTheBarItFallsIn() throws {
        let subject = try lane(
            summary([segmented(1, source: 2, steps: [64, 8])], stepsPerBar: 12), source: 2)

        #expect(subject.barCount == 6)
        #expect(subject.handles.map(\.bar) == [6])
    }
}
