import Foundation
import KSPKit
import KSPMIDI

/// Where the export lays each Pattern on one timeline: the shared slot spans, and what each track
/// fills of the span it is given.
public struct ArrangementSummary: Sendable, Hashable {
    /// The whole run, repeats included.
    public let lengthTicks: Int
    public let ticksPerBeat: Int
    /// In play order, one per Pattern per repeat, as `arrange` emits them.
    public let slots: [ArrangedSlot]
    /// All four device tracks, whether or not they fill anything.
    public let tracks: [ArrangedLane]
    public let diagnostics: Report

    public init(
        lengthTicks: Int, ticksPerBeat: Int = MIDIExport.defaultTicksPerBeat,
        slots: [ArrangedSlot], tracks: [ArrangedLane], diagnostics: Report = Report()
    ) {
        self.lengthTicks = lengthTicks
        self.ticksPerBeat = ticksPerBeat
        self.slots = slots
        self.tracks = tracks
        self.diagnostics = diagnostics
    }

    public var isEmpty: Bool { slots.isEmpty }

    /// Every position comes off `arrange`, which is what marks the exported `.mid`. Nothing here
    /// works an offset out again: a preview that disagrees with the file is worse than none.
    init(renderings: [Rendering], arrangement: Arrangement, ticksPerBeat: Int) {
        let slots = Self.slots(arrangement)
        var lengths: [Int: [Int: Int]] = [:]
        var counts: [Int: [Int: Int]] = [:]
        var marks: [Int: [Int: [ArrangedMark]]] = [:]
        var melodic: Set<Int> = []
        for rendering in renderings {
            let track = rendering.trackNumber
            let pattern = rendering.patternNumber
            // Merged across kinds for the one case that renders both: `--include-stale` exports a
            // Pattern's leftover set beside its live one, and both play in the same slot.
            lengths[track, default: [:]][pattern] = max(
                lengths[track]?[pattern] ?? 0, rendering.lengthTicks)
            counts[track, default: [:]][pattern, default: 0] += rendering.notes.count
            marks[track, default: [:]][pattern, default: []]
                .append(contentsOf: rendering.notes.map(ArrangedMark.init))
            if rendering.kind != .drum { melodic.insert(track) }
        }
        self.init(
            lengthTicks: arrangement.lengthTicks, ticksPerBeat: ticksPerBeat, slots: slots,
            tracks: (1...Constants.trackItemIDs.count).map { track in
                ArrangedLane(
                    trackNumber: track, isDrum: !melodic.contains(track),
                    regions: slots.compactMap { slot in
                        guard let length = lengths[track]?[slot.patternNumber] else { return nil }
                        return ArrangedRegion(
                            patternNumber: slot.patternNumber, startTick: slot.startTick,
                            spanTicks: slot.lengthTicks, lengthTicks: length,
                            noteCount: counts[track]?[slot.patternNumber] ?? 0,
                            marks: marks[track]?[slot.patternNumber] ?? [])
                    })
            },
            diagnostics: arrangement.diagnostics)
    }

    /// A span runs to the next boundary, and the last to the end of the run.
    private static func slots(_ arrangement: Arrangement) -> [ArrangedSlot] {
        arrangement.boundaries.indices.map { index in
            let boundary = arrangement.boundaries[index]
            let next =
                index + 1 < arrangement.boundaries.count
                ? arrangement.boundaries[index + 1].tick : arrangement.lengthTicks
            return ArrangedSlot(
                patternNumber: boundary.patternNumber, startTick: boundary.tick,
                lengthTicks: next - boundary.tick)
        }
    }
}

/// One Pattern's place on the timeline, shared by all four tracks. `arrange` gives a slot the
/// longest length any track gives it, which is what keeps the tracks aligned at every boundary.
public struct ArrangedSlot: Sendable, Hashable {
    /// 1-16.
    public let patternNumber: Int
    public let startTick: Int
    public let lengthTicks: Int

    public init(patternNumber: Int, startTick: Int, lengthTicks: Int) {
        self.patternNumber = patternNumber
        self.startTick = startTick
        self.lengthTicks = lengthTicks
    }
}

/// One device track's lane. A slot it fills nothing of gets no region at all, which is the gap a
/// track playing fewer Patterns than its neighbours leaves.
public struct ArrangedLane: Sendable, Hashable {
    /// 1-4.
    public let trackNumber: Int
    /// Only where every Pattern it plays renders as drums: a stale melodic set is not a drum track.
    public let isDrum: Bool
    public let regions: [ArrangedRegion]

    public init(trackNumber: Int, isDrum: Bool = false, regions: [ArrangedRegion] = []) {
        self.trackNumber = trackNumber
        self.isDrum = isDrum
        self.regions = regions
    }

    public var isEmpty: Bool { regions.isEmpty }

    /// What the exported `.mid` calls this track, so the lane and the file agree.
    public var name: String { Rendering.trackName(trackNumber, kind: isDrum ? .drum : .seq) }

    public var noteCount: Int { regions.reduce(0) { $0 + $1.noteCount } }

    /// In play order, one entry per repeat of a Pattern.
    public var patterns: [Int] { regions.map(\.patternNumber) }
}

/// What one track holds in one slot, drawn at its own length inside the shared span.
public struct ArrangedRegion: Sendable, Hashable {
    public let patternNumber: Int
    /// The slot's, so every track starts a Pattern together.
    public let startTick: Int
    /// The slot's length, which is the longest any track gives this Pattern.
    public let spanTicks: Int
    /// This track's own, never stretched to the span: the difference is what the device plays.
    public let lengthTicks: Int
    public let noteCount: Int
    /// Ticks are the region's own, as `renderPattern` leaves them before `arrange` offsets them.
    public let marks: [ArrangedMark]

    public init(
        patternNumber: Int, startTick: Int, spanTicks: Int, lengthTicks: Int, noteCount: Int,
        marks: [ArrangedMark] = []
    ) {
        self.patternNumber = patternNumber
        self.startTick = startTick
        self.spanTicks = spanTicks
        self.lengthTicks = lengthTicks
        self.noteCount = noteCount
        self.marks = marks
    }

    /// Held but silent: the Pattern rendered, and every event in it was switched off.
    public var isEmpty: Bool { noteCount == 0 }

    /// The span this track leaves unplayed, which the device fills by looping back.
    public var gapTicks: Int { max(0, spanTicks - lengthTicks) }
}

/// One rendered event, for a preview that sketches the rhythm rather than naming the notes.
public struct ArrangedMark: Sendable, Hashable {
    public let tick: Int
    public let durationTicks: Int
    public let pitch: Int

    public init(tick: Int, durationTicks: Int, pitch: Int) {
        self.tick = tick
        self.durationTicks = durationTicks
        self.pitch = pitch
    }

    init(_ note: RenderedNote) {
        self.init(tick: note.tick, durationTicks: note.durationTicks, pitch: note.pitch)
    }
}
