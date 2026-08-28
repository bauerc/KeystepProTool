import Foundation
import KSPKit
import KSPMIDI

/// What an import would lay down, said before anything is written: the device tracks it fills, the
/// patterns each one takes, and the source tracks that will not fit at all.
public struct SegmentationSummary: Sendable, Hashable {
    /// In the plan's own order, which is device track order.
    public let tracks: [SegmentedTrack]
    /// Source tracks holding notes that the plan gave no device track.
    public let unplaced: [UnplacedSource]
    public let diagnostics: Report

    public init(
        tracks: [SegmentedTrack], unplaced: [UnplacedSource] = [], diagnostics: Report = Report()
    ) {
        self.tracks = tracks
        self.unplaced = unplaced
        self.diagnostics = diagnostics
    }

    public var isEmpty: Bool { tracks.isEmpty }

    /// Every figure is read off the plan the conversion would run on. Nothing here re-decides what
    /// `planTrack` decided, because a preview that disagrees with the conversion is worse than none.
    init(song: Song, plan: SongPlan) {
        let dropped = droppedPatterns(plan.diagnostics)
        self.init(
            tracks: plan.tracks.map { SegmentedTrack($0, droppedPatterns: dropped[$0.track] ?? 0) },
            unplaced: unplacedSources(song, plan), diagnostics: plan.diagnostics)
    }
}

/// One device track's worth of the import: the patterns it fills, in play order.
public struct SegmentedTrack: Sendable, Hashable {
    public let deviceTrack: Int
    /// A clip merged from several source tracks has no one source track, so it gets no number.
    public let sourceTrack: Int?
    public let sourceFile: String
    public let isDrum: Bool
    public let noteCount: Int
    public let segments: [Segment]
    /// Patterns the run needed past the last one free, which the planner dropped the tail of.
    public let droppedPatterns: Int

    public init(
        deviceTrack: Int, sourceTrack: Int? = nil, sourceFile: String = "", isDrum: Bool = false,
        noteCount: Int = 0, segments: [Segment] = [], droppedPatterns: Int = 0
    ) {
        self.deviceTrack = deviceTrack
        self.sourceTrack = sourceTrack
        self.sourceFile = sourceFile
        self.isDrum = isDrum
        self.noteCount = noteCount
        self.segments = segments
        self.droppedPatterns = droppedPatterns
    }

    init(_ plan: TrackPlan, droppedPatterns: Int) {
        // A running total of the planner's own step counts, so where the cut falls is reported
        // rather than recomputed from the 64-step rule.
        var step = 1
        var segments: [Segment] = []
        for placement in plan.placements {
            segments.append(
                Segment(
                    pattern: placement.pattern, stepCount: placement.stepCount, firstStep: step))
            step += placement.stepCount
        }
        self.init(
            deviceTrack: plan.track, sourceTrack: plan.sourceTrack, sourceFile: plan.sourceFile,
            isDrum: plan.isDrum, noteCount: plan.notes.count, segments: segments,
            droppedPatterns: droppedPatterns)
    }

    public var patterns: [Int] { segments.map(\.pattern) }

    public var stepCount: Int { segments.reduce(0) { $0 + $1.stepCount } }

    public var isSplit: Bool { segments.count > 1 }
}

/// One pattern of a run, and where in the run it picks up.
public struct Segment: Sendable, Hashable {
    public let pattern: Int
    public let stepCount: Int
    /// Counting the run's own steps from 1: the split point, where this is not the first.
    public let firstStep: Int

    public init(pattern: Int, stepCount: Int, firstStep: Int = 1) {
        self.pattern = pattern
        self.stepCount = stepCount
        self.firstStep = firstStep
    }

    public var lastStep: Int { firstStep + stepCount - 1 }
}

/// A source track the import will read and then have nowhere to put.
public struct UnplacedSource: Sendable, Hashable {
    public let sourceTrack: Int
    public let sourceFile: String
    public let noteCount: Int

    public init(sourceTrack: Int, sourceFile: String = "", noteCount: Int = 0) {
        self.sourceTrack = sourceTrack
        self.sourceFile = sourceFile
        self.noteCount = noteCount
    }
}

private func droppedPatterns(_ report: Report) -> [Int: Int] {
    var dropped: [Int: Int] = [:]
    for entry in report where entry.code == .pastPatternEnd {
        guard let track = entry.site.track else { continue }
        dropped[track, default: 0] += entry.subjects
    }
    return dropped
}

/// The clips the planner read, minus the source tracks it gave a device track. Taking that
/// difference rather than repeating `assign`'s rule is what keeps this from being a second one.
private func unplacedSources(_ song: Song, _ plan: SongPlan) -> [UnplacedSource] {
    let placed = Set(plan.tracks.compactMap(\.sourceTrack))
    var order: [Int] = []
    var notes: [Int: Int] = [:]
    var files: [Int: String] = [:]
    for clip in song.clips {
        guard let source = clip.sourceTracks.first, !placed.contains(source) else { continue }
        if notes[source] == nil {
            order.append(source)
            files[source] = clip.sourceFile
        }
        notes[source, default: 0] += clip.notes.count
    }
    return order.map {
        UnplacedSource(
            sourceTrack: $0, sourceFile: files[$0] ?? "", noteCount: notes[$0] ?? 0)
    }
}
