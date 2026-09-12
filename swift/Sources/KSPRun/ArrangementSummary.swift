import Foundation
import KSPKit
import KSPMIDI

public struct ArrangementSummary: Sendable, Hashable {
    public let lengthTicks: Int
    public let ticksPerBeat: Int
    public let slots: [ArrangedSlot]
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

    init(renderings: [Rendering], arrangement: Arrangement, ticksPerBeat: Int) {
        let slots = Self.slots(arrangement)
        var lengths: [Int: [Int: Int]] = [:]
        var counts: [Int: [Int: Int]] = [:]
        var marks: [Int: [Int: [ArrangedMark]]] = [:]
        var melodic: Set<Int> = []
        for rendering in renderings {
            let track = rendering.trackNumber
            let pattern = rendering.patternNumber
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
                let regions = slots.compactMap { slot -> ArrangedRegion? in
                    guard let length = lengths[track]?[slot.patternNumber] else { return nil }
                    return ArrangedRegion(
                        patternNumber: slot.patternNumber, startTick: slot.startTick,
                        spanTicks: slot.lengthTicks, lengthTicks: length,
                        noteCount: counts[track]?[slot.patternNumber] ?? 0,
                        marks: marks[track]?[slot.patternNumber] ?? [])
                }
                return ArrangedLane(
                    trackNumber: track, isDrum: !regions.isEmpty && !melodic.contains(track),
                    regions: regions)
            },
            diagnostics: arrangement.diagnostics)
    }

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

public struct ArrangedLane: Sendable, Hashable {
    /// 1-4.
    public let trackNumber: Int
    public let isDrum: Bool
    public let regions: [ArrangedRegion]

    public init(trackNumber: Int, isDrum: Bool = false, regions: [ArrangedRegion] = []) {
        self.trackNumber = trackNumber
        self.isDrum = isDrum
        self.regions = regions
    }

    public var isEmpty: Bool { regions.isEmpty }

    public var name: String { Rendering.trackName(trackNumber, kind: isDrum ? .drum : .seq) }

    public var noteCount: Int { regions.reduce(0) { $0 + $1.noteCount } }

    public var patterns: [Int] { regions.map(\.patternNumber) }
}

public struct ArrangedRegion: Sendable, Hashable {
    public let patternNumber: Int
    public let startTick: Int
    public let spanTicks: Int
    public let lengthTicks: Int
    public let noteCount: Int
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

    public var isEmpty: Bool { noteCount == 0 }

    public var gapTicks: Int { max(0, spanTicks - lengthTicks) }
}

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
