import Foundation
import KSPKit
import KSPRun

/// The four tracks on one time axis: a region per Pattern, at the length that track plays it. The
/// geometry is the export's own, scaled into ``AppLayout/axisWidth``; this only measures it out.
struct ArrangeLanes: Equatable {
    struct Region: Equatable {
        /// Which slot of the run this is, counting from 0. A repeated Pattern is several slots.
        let slot: Int
        /// 1-16.
        let pattern: Int
        let label: String
        /// From the axis's leading edge, and the width this track fills of its slot.
        let x: CGFloat
        let width: CGFloat
        /// Held, and every event in it switched off.
        let isEmpty: Bool
        let showsLabel: Bool
        /// Dropped below a width where the marks would outnumber the points available.
        let showsMarks: Bool
        let marks: [NoteMark]
        /// On the run's own clock rather than restarted per Pattern, so a note the export moved
        /// off the grid -- by swing or by time shift -- is seen to sit off it.
        let beatLines: [CGFloat]
        let detail: String

        init(
            _ region: ArrangedRegion, slot: Int, total: Int, ticksPerBeat: Int,
            window: PitchWindow, beatStride: Int
        ) {
            let width = AppLayout.width(ofTicks: region.lengthTicks, in: total)
            let showsMarks = width >= AppLayout.marksMinimumWidth
            self.slot = slot
            self.pattern = region.patternNumber
            self.label = "\(region.patternNumber)"
            self.x = AppLayout.x(ofTick: region.startTick, in: total)
            self.width = width
            self.isEmpty = region.isEmpty
            self.showsLabel = width >= AppLayout.regionLabelMinimumWidth
            self.showsMarks = showsMarks
            self.marks = Self.marks(region, total: total, width: width, window: window)
            self.beatLines =
                showsMarks ? Self.ruled(region, total: total, every: beatStride * ticksPerBeat) : []
            self.detail = Self.detail(region, ticksPerBeat: ticksPerBeat)
        }

        /// Scaled against the whole run, as the region itself is, then held inside the region: a
        /// note whose gate runs past the last step would otherwise draw over its neighbour.
        private static func marks(
            _ region: ArrangedRegion, total: Int, width: CGFloat, window: PitchWindow
        ) -> [NoteMark] {
            region.marks.map { mark in
                let x = min(AppLayout.x(ofTick: mark.tick, in: total), width)
                let length = max(
                    AppLayout.width(ofTicks: mark.durationTicks, in: total),
                    AppLayout.markMinWidth)
                return NoteMark(
                    x: x, width: min(length, max(width - x, 0)),
                    y: window.y(
                        ofPitch: mark.pitch, in: AppLayout.laneHeight,
                        markHeight: AppLayout.markHeight))
            }
        }

        /// The region's own start is a boundary, drawn already, so the first line is the next one.
        private static func ruled(_ region: ArrangedRegion, total: Int, every: Int) -> [CGFloat] {
            guard every > 0 else { return [] }
            let origin = AppLayout.x(ofTick: region.startTick, in: total)
            return stride(
                from: (region.startTick / every + 1) * every,
                to: region.startTick + region.lengthTicks, by: every
            ).map { AppLayout.x(ofTick: $0, in: total) - origin }
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
        /// Counting from 0, so two boundaries falling on one tick stay distinct.
        let slot: Int
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
        /// What the lane's pitch window is fitted to, named under the track.
        let range: String?
        let middleC: CGFloat?
        let regions: [Region]

        init(_ lane: ArrangedLane, total: Int, ticksPerBeat: Int, beatStride: Int) {
            let pitches = lane.regions.flatMap { $0.marks.map(\.pitch) }
            let window = PitchWindow(pitches)
            self.track = lane.trackNumber
            self.name = "Track \(lane.trackNumber)"
            self.readout = patternReadout(lane.regions.first?.patternNumber)
            self.isDrum = lane.isDrum
            self.isEmpty = lane.isEmpty
            self.detail = Self.detail(lane, ticksPerBeat: ticksPerBeat)
            self.range = pitchRange(pitches)
            self.middleC =
                pitches.isEmpty
                ? nil : window.middleC(in: AppLayout.laneHeight, markHeight: AppLayout.markHeight)
            self.regions = lane.regions.enumerated().map {
                Region(
                    $0.element, slot: $0.offset, total: total, ticksPerBeat: ticksPerBeat,
                    window: window, beatStride: beatStride)
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
    }

    let header: String
    let boundaries: [Boundary]
    let lanes: [Lane]

    init(_ summary: ArrangementSummary) {
        let total = summary.lengthTicks
        self.header =
            counted(summary.slots.count, "pattern") + " · "
            + beats(total, ticksPerBeat: summary.ticksPerBeat) + " end to end"
        self.boundaries = summary.slots.enumerated().map {
            Boundary(
                slot: $0.offset, pattern: $0.element.patternNumber,
                x: AppLayout.x(ofTick: $0.element.startTick, in: total))
        }
        let beatStride = AppLayout.beatStride(
            beatWidth: AppLayout.width(ofTicks: summary.ticksPerBeat, in: total))
        self.lanes = summary.tracks.map {
            Lane($0, total: total, ticksPerBeat: summary.ticksPerBeat, beatStride: beatStride)
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
