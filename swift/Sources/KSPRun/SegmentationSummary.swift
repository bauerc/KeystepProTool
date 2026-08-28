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
    /// The song's own bar, in steps, which is what turns a step count into the bars a boundary
    /// may be named at.
    public let stepsPerBar: Int

    public init(
        tracks: [SegmentedTrack], unplaced: [UnplacedSource] = [],
        stepsPerBar: Int = Constants.defaultStepsPerBeat * 4
    ) {
        self.tracks = tracks
        self.unplaced = unplaced
        self.stepsPerBar = stepsPerBar
    }

    public var isEmpty: Bool { tracks.isEmpty }

    /// Every figure is read off the plan the conversion would run on. Nothing here re-decides what
    /// `planTrack` decided, because a preview that disagrees with the conversion is worse than none.
    init(song: Song, plan: SongPlan, stepsPerBar: Int) {
        let dropped = droppedPatterns(plan.diagnostics)
        self.init(
            tracks: plan.tracks.map { SegmentedTrack($0, droppedPatterns: dropped[$0.track] ?? 0) },
            unplaced: unplacedSources(song, plan), stepsPerBar: stepsPerBar)
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

    /// The run's length in bars, which is the span a boundary may fall inside.
    public func barCount(stepsPerBar: Int) -> Int {
        max(1, Arithmetic.ceilDiv(stepCount, max(1, stepsPerBar)))
    }
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

    /// The bar this pattern begins at, counted from 1 as `--segment-bars` counts. The automatic
    /// split cuts every 64 steps, which is a whole number of bars only where the bar divides 64,
    /// so a cut that falls mid-bar reports the bar it falls in.
    public func firstBar(stepsPerBar: Int) -> Int {
        Arithmetic.floorDiv(firstStep - 1, max(1, stepsPerBar)) + 1
    }
}

/// A source track the import will read and then have nowhere to put, in whole or in the part of
/// it one channel makes.
public struct UnplacedSource: Sendable, Hashable {
    public let sourceTrack: Int
    public let sourceFile: String
    /// Counted in parts, one per channel: a source track carrying several becomes a device track
    /// apiece, and the device can run out between them.
    public let droppedParts: Int
    public let placedParts: Int
    /// Notes across the whole source track, which is what it loses only where none of it landed.
    public let noteCount: Int

    public init(
        sourceTrack: Int, sourceFile: String = "", droppedParts: Int = 1, placedParts: Int = 0,
        noteCount: Int = 0
    ) {
        self.sourceTrack = sourceTrack
        self.sourceFile = sourceFile
        self.droppedParts = droppedParts
        self.placedParts = placedParts
        self.noteCount = noteCount
    }

    public var isWhole: Bool { placedParts == 0 }

    public var parts: Int { placedParts + droppedParts }
}

private func droppedPatterns(_ report: Report) -> [Int: Int] {
    var dropped: [Int: Int] = [:]
    for entry in report where entry.code == .pastPatternEnd {
        // Load-bearing, not defensive: `quantise` raises this code counting dropped *notes* and
        // names no track, while `planTrack` counts dropped *patterns* and names one.
        guard let track = entry.site.track else { continue }
        dropped[track, default: 0] += entry.subjects
    }
    return dropped
}

/// The parts the planner read against the parts it gave a device track. Counted per part rather
/// than per source track, or a track that gave up one channel and kept another would read as whole.
private func unplacedSources(_ song: Song, _ plan: SongPlan) -> [UnplacedSource] {
    var placed: [Int: Int] = [:]
    for track in plan.tracks {
        guard let source = track.sourceTrack else { continue }
        placed[source, default: 0] += 1
    }

    var order: [Int] = []
    var parts: [Int: Int] = [:]
    var notes: [Int: Int] = [:]
    var files: [Int: String] = [:]
    for clip in song.clips {
        guard let source = clip.sourceTracks.first else { continue }
        if parts[source] == nil {
            order.append(source)
            files[source] = clip.sourceFile
        }
        parts[source, default: 0] += 1
        notes[source, default: 0] += clip.notes.count
    }

    return order.compactMap { source in
        let landed = placed[source] ?? 0
        let dropped = (parts[source] ?? 0) - landed
        guard dropped > 0 else { return nil }
        return UnplacedSource(
            sourceTrack: source, sourceFile: files[source] ?? "", droppedParts: dropped,
            placedParts: landed, noteCount: notes[source] ?? 0)
    }
}
