import Foundation
import KSPKit
import KSPRun

struct NoteMark: Equatable {
    let x: CGFloat
    let width: CGFloat
    let y: CGFloat
}

struct GridLine: Equatable {
    let x: CGFloat
    let accented: Bool
}

func gridLines(
    after start: Int, before end: Int, stride: Int, group: Int, x: (Int) -> CGFloat
) -> [GridLine] {
    guard stride > 0 else { return [] }
    let accent = stride * max(group, 1)
    return Swift.stride(from: (start / stride + 1) * stride, to: end, by: stride).map {
        GridLine(x: x($0), accented: $0 % accent == 0)
    }
}

struct PitchWindow: Equatable {
    /// The device shows MIDI 60 as C3 (visual language, rule 3), and every shape rules a line there.
    static let middleC = 60

    let low: Int
    let high: Int

    init(_ pitches: [Int]) {
        let lowest = pitches.min() ?? Self.middleC
        let highest = pitches.max() ?? Self.middleC
        let short = max(0, AppLayout.pitchWindowMinimumSpan - (highest - lowest))
        self.low = lowest - short / 2
        self.high = highest + (short - short / 2)
    }

    func y(ofPitch pitch: Int, in height: CGFloat, markHeight: CGFloat) -> CGFloat {
        let clamped = min(max(pitch, low), high)
        return (height - markHeight) * (1 - CGFloat(clamped - low) / CGFloat(high - low))
    }

    func middleC(in height: CGFloat, markHeight: CGFloat) -> CGFloat? {
        guard (low...high).contains(Self.middleC) else { return nil }
        return y(ofPitch: Self.middleC, in: height, markHeight: markHeight) + markHeight / 2
    }
}

func pitchRange(_ pitches: [Int]) -> String? {
    guard let low = pitches.min(), let high = pitches.max() else { return nil }
    let name = Constants.noteName
    return low == high ? name(low) : "\(name(low))–\(name(high))"
}

extension NoteMark {
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

struct NoteShape: Equatable {
    struct Region: Equatable {
        /// 1-16.
        let pattern: Int
        let x: CGFloat
        let width: CGFloat
        let isEmpty: Bool
        let marks: [NoteMark]
        let grid: [GridLine]
        let bracket: String
        let showsBracket: Bool
    }

    struct PitchLabel: Equatable {
        let text: String
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

    var spoken: String {
        let range = range.map { ["pitches \($0)"] } ?? []
        return aloud(([detail] + range + regions.map(\.bracket)).joined(separator: " · "))
    }

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
            grid: ruling(segment, step: step),
            bracket: "pattern \(segment.pattern) · \(counted(segment.stepCount, "step"))",
            showsBracket: width >= AppLayout.bracketLabelMinimumWidth)
    }

    private static func ruling(_ segment: Segment, step: CGFloat) -> [GridLine] {
        let group = segment.stepsPerBeat
        return gridLines(
            after: 0, before: segment.stepCount,
            stride: AppLayout.gridStride(unitWidth: step, group: group), group: group
        ) { CGFloat($0) * step }
    }

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
