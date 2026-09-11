import Foundation
import KSPKit
import KSPRun

/// One note drawn, in its region's own points.
struct NoteMark: Equatable {
    let x: CGFloat
    let width: CGFloat
    let y: CGFloat
}

/// The pitches a shape is drawn across: fitted to what it holds, because its range is named beside
/// it, rather than clamped into one window for every file.
struct PitchWindow: Equatable {
    /// The device shows MIDI 60 as C3 (visual language, rule 3), and every shape rules a line there.
    static let middleC = 60

    let low: Int
    let high: Int

    /// A window over nothing centres on C3, so it still has an answer to give.
    init(_ pitches: [Int]) {
        let lowest = pitches.min() ?? Self.middleC
        let highest = pitches.max() ?? Self.middleC
        let short = max(0, AppLayout.pitchWindowMinimumSpan - (highest - lowest))
        self.low = lowest - short / 2
        self.high = highest + (short - short / 2)
    }

    /// The top of a mark `markHeight` tall in a band `height` tall, high pitch at the top.
    func y(ofPitch pitch: Int, in height: CGFloat, markHeight: CGFloat) -> CGFloat {
        let clamped = min(max(pitch, low), high)
        return (height - markHeight) * (1 - CGFloat(clamped - low) / CGFloat(high - low))
    }

    /// Centred where a C3 note would sit, or nil where the window does not reach it.
    func middleC(in height: CGFloat, markHeight: CGFloat) -> CGFloat? {
        guard (low...high).contains(Self.middleC) else { return nil }
        return y(ofPitch: Self.middleC, in: height, markHeight: markHeight) + markHeight / 2
    }
}

/// The lowest and highest pitch held, in the device's numerals: `C2–C5`, or one name for one.
func pitchRange(_ pitches: [Int]) -> String? {
    guard let low = pitches.min(), let high = pitches.max() else { return nil }
    let name = Constants.noteName
    return low == high ? name(low) : "\(name(low))–\(name(high))"
}

extension NoteMark {
    /// `note` in a Pattern drawn `width` by `height`, at `step` points a step. Held inside it: the
    /// device loops at a Pattern's last step rather than sustaining past it.
    init(
        _ note: SegmentNote, step: CGFloat, width: CGFloat, height: CGFloat, markHeight: CGFloat,
        window: PitchWindow
    ) {
        let x = CGFloat(note.step - 1) * step
        let length = max(CGFloat(note.length) * step, AppLayout.markMinWidth)
        self.init(
            x: x, width: min(length, max(width - x, 0)),
            y: window.y(ofPitch: note.pitch, in: height, markHeight: markHeight))
    }
}

/// One device track's run as the import would lay it down: pitch up, steps across, a region per
/// Pattern. Every shape of a plan shares one step axis, so a shorter run is drawn shorter.
struct NoteShape: Equatable {
    struct Region: Equatable {
        /// 1-16.
        let pattern: Int
        let x: CGFloat
        let width: CGFloat
        let isEmpty: Bool
        let marks: [NoteMark]
        /// Counted from the Pattern's own first step, as the device counts its steps.
        let beatLines: [CGFloat]
        let bracket: String
        /// Narrower than its words, a bracket is drawn bare and says them on hover.
        let showsBracket: Bool
    }

    struct PitchLabel: Equatable {
        let text: String
        /// The label's top edge.
        let y: CGFloat
    }

    /// 1-4.
    let track: Int
    let name: String
    let range: String?
    let detail: String
    let regions: [Region]
    let middleC: CGFloat?
    let labels: [PitchLabel]

    init(_ track: SegmentedTrack, stepsAcross: Int) {
        let pitches = track.segments.flatMap { $0.notes.map(\.pitch) }
        let window = PitchWindow(pitches)
        let step = stepsAcross > 0 ? AppLayout.axisWidth / CGFloat(stepsAcross) : 0
        self.track = track.deviceTrack
        self.name = "Track \(track.deviceTrack)"
        self.range = pitchRange(pitches)
        self.detail = [
            counted(track.noteCount, track.isDrum ? "trigger" : "note"), located(track.patterns),
            counted(track.stepCount, "step") + " in all",
        ].joined(separator: " · ")
        self.regions = track.segments.map { Self.region($0, step: step, window: window) }
        self.middleC =
            pitches.isEmpty
            ? nil : window.middleC(in: AppLayout.laneHeight, markHeight: AppLayout.markHeight)
        self.labels = Self.labels(pitches, window: window)
    }

    /// A shape for every track the plan fills, all on the longest run's step axis.
    static func shapes(_ summary: SegmentationSummary) -> [NoteShape] {
        let filled = summary.tracks.filter { !$0.segments.isEmpty }
        let across = filled.map(\.stepCount).max() ?? 0
        return filled.map { NoteShape($0, stepsAcross: across) }
    }

    private static func region(_ segment: Segment, step: CGFloat, window: PitchWindow) -> Region {
        let width = CGFloat(segment.stepCount) * step
        return Region(
            pattern: segment.pattern, x: CGFloat(segment.firstStep - 1) * step, width: width,
            isEmpty: segment.notes.isEmpty,
            marks: segment.notes.map {
                NoteMark(
                    $0, step: step, width: width, height: AppLayout.laneHeight,
                    markHeight: AppLayout.markHeight, window: window)
            },
            beatLines: ruled(segment, step: step),
            bracket: "pattern \(segment.pattern) · \(counted(segment.stepCount, "step"))",
            showsBracket: width >= AppLayout.bracketLabelMinimumWidth)
    }

    private static func ruled(_ segment: Segment, step: CGFloat) -> [CGFloat] {
        let apart = AppLayout.beatStride(beatWidth: CGFloat(segment.stepsPerBeat) * step)
        let every = apart * segment.stepsPerBeat
        guard every > 0 else { return [] }
        return stride(from: every, to: segment.stepCount, by: every).map { CGFloat($0) * step }
    }

    /// C3 first, because it names the one line across the shape, then the two ends of the range. A
    /// label that would overprint one already placed is left to the range beside the name.
    private static func labels(_ pitches: [Int], window: PitchWindow) -> [PitchLabel] {
        guard let lowest = pitches.min(), let highest = pitches.max() else { return [] }
        let height = AppLayout.laneHeight
        let mark = AppLayout.markHeight
        var candidates = [lowest, highest]
        if window.middleC(in: height, markHeight: mark) != nil {
            candidates.insert(PitchWindow.middleC, at: 0)
        }
        var placed: [(pitch: Int, centre: CGFloat)] = []
        for pitch in candidates where !placed.contains(where: { $0.pitch == pitch }) {
            let centre = window.y(ofPitch: pitch, in: height, markHeight: mark) + mark / 2
            guard placed.allSatisfy({ abs($0.centre - centre) >= AppLayout.pitchLabelHeight })
            else { continue }
            placed.append((pitch, centre))
        }
        return placed.sorted { $0.centre < $1.centre }.map {
            let top = min(
                max($0.centre - AppLayout.pitchLabelHeight / 2, 0),
                height - AppLayout.pitchLabelHeight)
            return PitchLabel(text: Constants.noteName($0.pitch), y: top)
        }
    }
}
