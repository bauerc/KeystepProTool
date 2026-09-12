import Foundation
import KSPKit
import KSPMIDI

public struct SegmentationSummary: Sendable, Hashable {
    public let tracks: [SegmentedTrack]
    public let unplaced: [UnplacedSource]

    public init(tracks: [SegmentedTrack], unplaced: [UnplacedSource] = []) {
        self.tracks = tracks
        self.unplaced = unplaced
    }

    public var isEmpty: Bool { tracks.isEmpty }

    init(song: Song, plan: SongPlan) {
        let dropped = droppedPatterns(plan.diagnostics)
        let overflowed = droppedNotes(plan.diagnostics)
        self.init(
            tracks: plan.tracks.map {
                SegmentedTrack(
                    $0, droppedPatterns: dropped[$0.track] ?? 0,
                    droppedNotes: overflowed[$0.track] ?? [:])
            },
            unplaced: unplacedSources(song, plan))
    }
}

public struct SegmentedTrack: Sendable, Hashable {
    public let deviceTrack: Int
    public let sourceTrack: Int?
    public let sourceFile: String
    public let isDrum: Bool
    public let noteCount: Int
    public let segments: [Segment]
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

    init(_ plan: TrackPlan, droppedPatterns: Int, droppedNotes: [Int: Int] = [:]) {
        var step = 1
        var segments: [Segment] = []
        for placement in plan.placements {
            segments.append(
                Segment(
                    pattern: placement.pattern, stepCount: placement.stepCount, firstStep: step,
                    noteCount: placement.notes.count,
                    mostNotesOnAStep: mostNotesOnAStep(placement.notes),
                    droppedNotes: droppedNotes[placement.pattern] ?? 0,
                    notes: placement.notes.map(SegmentNote.init),
                    stepsPerBeat: placement.stepsPerBeat))
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

public struct Segment: Sendable, Hashable {
    public let pattern: Int
    public let stepCount: Int
    /// Counting the run's own steps from 1: the split point, where this is not the first.
    public let firstStep: Int
    public let noteCount: Int
    public let mostNotesOnAStep: Int
    public let droppedNotes: Int
    public let notes: [SegmentNote]
    public let stepsPerBeat: Int

    public init(
        pattern: Int, stepCount: Int, firstStep: Int = 1, noteCount: Int = 0,
        mostNotesOnAStep: Int = 0,
        droppedNotes: Int = 0, notes: [SegmentNote] = [],
        stepsPerBeat: Int = Constants.defaultStepsPerBeat
    ) {
        self.pattern = pattern
        self.stepCount = stepCount
        self.firstStep = firstStep
        self.noteCount = noteCount
        self.mostNotesOnAStep = mostNotesOnAStep
        self.droppedNotes = droppedNotes
        self.notes = notes
        self.stepsPerBeat = stepsPerBeat
    }

    public var lastStep: Int { firstStep + stepCount - 1 }
}

public struct SegmentNote: Sendable, Hashable {
    /// Counting the pattern's own steps from 1, not the run's.
    public let step: Int
    public let pitch: Int
    public let length: Double

    public init(step: Int, pitch: Int, length: Double = Constants.defaultGateLength) {
        self.step = step
        self.pitch = pitch
        self.length = length
    }

    init(_ note: PlacedNote) {
        self.init(
            step: note.step, pitch: note.pitch,
            length: Constants.decodeGate(note.gate) ?? Constants.defaultGateLength)
    }
}

public struct UnplacedSource: Sendable, Hashable {
    public let sourceTrack: Int
    public let sourceFile: String
    public let droppedParts: Int
    public let placedParts: Int
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
        // Load-bearing, not defensive: `quantise` raises this code counting dropped *notes*,
        // `planTrack` counting dropped *patterns*.
        guard let track = entry.site.track else { continue }
        dropped[track, default: 0] += entry.subjects
    }
    return dropped
}

private func droppedNotes(_ report: Report) -> [Int: [Int: Int]] {
    var dropped: [Int: [Int: Int]] = [:]
    for entry in report where entry.code == .poolOverflow {
        guard let track = entry.site.track, let pattern = entry.site.pattern else { continue }
        dropped[track, default: [:]][pattern, default: 0] += entry.subjects
    }
    return dropped
}

private func mostNotesOnAStep(_ notes: [PlacedNote]) -> Int {
    var held: [Int: Int] = [:]
    for note in notes {
        held[note.step, default: 0] += 1
    }
    return held.values.max() ?? 0
}

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
