import Foundation
import KSPKit
import KSPRun

/// The four tracks on one time axis: a region per Pattern, at the length that track plays it. The
/// geometry is the export's own, scaled into ``AppLayout/axisWidth``; this only measures it out.
struct ArrangeLanes: Equatable {
    static let legend =
        "A region is one Pattern at the length its own track plays. Hover one for what it holds."

    /// One event of the region's sketch, in the region's own coordinates.
    struct Mark: Equatable {
        let x: CGFloat
        let width: CGFloat
        let y: CGFloat
    }

    struct Region: Equatable {
        /// 1-16.
        let pattern: Int
        let label: String
        /// From the axis's leading edge, and the width this track fills of its slot.
        let x: CGFloat
        let width: CGFloat
        /// The slot every track shares, which ``width`` may fall short of.
        let spanWidth: CGFloat
        /// Held, and every event in it switched off.
        let isEmpty: Bool
        let noteCount: Int
        let showsLabel: Bool
        /// Dropped below a width where the marks would outnumber the points available.
        let showsMarks: Bool
        let marks: [Mark]
        let detail: String

        init(_ region: ArrangedRegion, total: Int, ticksPerBeat: Int) {
            let width = AppLayout.width(ofTicks: region.lengthTicks, in: total)
            self.pattern = region.patternNumber
            self.label = "\(region.patternNumber)"
            self.x = AppLayout.x(ofTick: region.startTick, in: total)
            self.width = width
            self.spanWidth = AppLayout.width(ofTicks: region.spanTicks, in: total)
            self.isEmpty = region.isEmpty
            self.noteCount = region.noteCount
            self.showsLabel = width >= AppLayout.regionLabelMinimumWidth
            self.showsMarks = width >= AppLayout.marksMinimumWidth
            self.marks = Self.marks(region, total: total, width: width)
            self.detail = Self.detail(region, ticksPerBeat: ticksPerBeat)
        }

        /// Scaled against the whole run, as the region itself is, then held inside the region: a
        /// note whose gate runs past the last step would otherwise draw over its neighbour.
        private static func marks(_ region: ArrangedRegion, total: Int, width: CGFloat) -> [Mark] {
            region.marks.map { mark in
                let x = min(AppLayout.x(ofTick: mark.tick, in: total), width)
                let length = max(
                    AppLayout.width(ofTicks: mark.durationTicks, in: total),
                    AppLayout.markMinWidth)
                return Mark(
                    x: x, width: min(length, max(width - x, 0)), y: AppLayout.y(ofPitch: mark.pitch)
                )
            }
        }

        private static func detail(_ region: ArrangedRegion, ticksPerBeat: Int) -> String {
            var parts = ["Pattern \(region.patternNumber)"]
            parts.append(
                region.isEmpty
                    ? "held, every event switched off" : counted(region.noteCount, "event"))
            parts.append("from beat \(beat(region.startTick, ticksPerBeat: ticksPerBeat))")
            if region.gapTicks > 0 {
                // The unequal case said in words as well as drawn, because the gap is the point.
                parts.append(
                    "loops back \(beats(region.gapTicks, ticksPerBeat: ticksPerBeat)) before the "
                        + "next pattern")
            }
            return parts.joined(separator: " · ")
        }
    }

    struct Boundary: Equatable {
        let pattern: Int
        let x: CGFloat
    }

    struct Lane: Equatable {
        /// 1-4.
        let track: Int
        let name: String
        /// The well: the first Pattern this track plays, or `--` where it plays none.
        let readout: String
        let isDrum: Bool
        let isEmpty: Bool
        let detail: String
        let regions: [Region]

        init(_ lane: ArrangedLane, total: Int, ticksPerBeat: Int) {
            self.track = lane.trackNumber
            self.name = "Track \(lane.trackNumber)"
            self.readout = patternReadout(lane.regions.first?.patternNumber)
            self.isDrum = lane.isDrum
            self.isEmpty = lane.isEmpty
            self.detail = Self.detail(lane, ticksPerBeat: ticksPerBeat)
            self.regions = lane.regions.map {
                Region($0, total: total, ticksPerBeat: ticksPerBeat)
            }
        }

        private static func detail(_ lane: ArrangedLane, ticksPerBeat: Int) -> String {
            guard !lane.isEmpty else { return "empty" }
            var parts: [String] = []
            if lane.isDrum { parts.append("drum") }
            parts.append(counted(lane.noteCount, lane.isDrum ? "trigger" : "note"))
            parts.append(located(lane.patterns))
            let played = lane.regions.reduce(0) { $0 + $1.lengthTicks }
            parts.append("\(beats(played, ticksPerBeat: ticksPerBeat)) in all")
            return parts.joined(separator: " · ")
        }

        /// Worded as `convert` words it, so the preview and the result read alike.
        private static func located(_ patterns: [Int]) -> String {
            let ordered = Set(patterns).sorted()
            guard let first = ordered.first, let last = ordered.last else { return "no pattern" }
            return ordered.count == 1 ? "pattern \(first)" : "patterns \(first)-\(last)"
        }
    }

    let header: String
    let boundaries: [Boundary]
    let lanes: [Lane]

    var isEmpty: Bool { boundaries.isEmpty }

    init(_ summary: ArrangementSummary) {
        let total = summary.lengthTicks
        self.header =
            counted(summary.slots.count, "pattern") + " · "
            + beats(total, ticksPerBeat: summary.ticksPerBeat) + " end to end"
        self.boundaries = summary.slots.map {
            Boundary(pattern: $0.patternNumber, x: AppLayout.x(ofTick: $0.startTick, in: total))
        }
        self.lanes = summary.tracks.map {
            Lane($0, total: total, ticksPerBeat: summary.ticksPerBeat)
        }
    }
}

/// Ticks are the export's unit and beats are the tempo's; the device counts neither, so the one a
/// reader can hear is the one shown. A triplet division leaves a fraction, which is kept.
private func beats(_ ticks: Int, ticksPerBeat: Int) -> String {
    guard ticksPerBeat > 0 else { return counted(0, "beat") }
    let count = Double(ticks) / Double(ticksPerBeat)
    return count == count.rounded()
        ? counted(Int(count), "beat") : "\(Arithmetic.general(count)) beats"
}

/// Counting from 1, as a musician counts and as the export's markers land.
private func beat(_ tick: Int, ticksPerBeat: Int) -> String {
    guard ticksPerBeat > 0 else { return "1" }
    return Arithmetic.general(Double(tick) / Double(ticksPerBeat) + 1)
}
