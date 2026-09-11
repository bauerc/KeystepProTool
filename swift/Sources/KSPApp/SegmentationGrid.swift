import Foundation
import KSPKit
import KSPRun

/// What the import would lay down, drawn as the export grid is: four device tracks down, sixteen
/// pattern slots across. Every figure comes from the planner; this only arranges them.
struct SegmentationGrid: Equatable {
    struct Cell: Equatable {
        /// 1-16.
        let pattern: Int
        /// Only an empty slot has a figure: a held one draws its Pattern instead.
        let label: String?
        let isEmpty: Bool
        /// What the slot will hold, which the fill's intensity is of.
        let noteCount: Int
        /// What it will run for, which the length rule is a fraction of.
        let stepCount: Int
        /// The Pattern in miniature, in the cell's own points, on its track's pitch window.
        let thumbnail: [NoteMark]
        let detail: String

        init(pattern: Int, segment: Segment?, track: SegmentedTrack?, window: PitchWindow) {
            self.pattern = pattern
            self.label = segment == nil ? "—" : nil
            self.isEmpty = segment == nil
            self.noteCount = segment?.noteCount ?? 0
            self.stepCount = segment?.stepCount ?? 0
            self.thumbnail = segment.map { Self.thumbnail($0, window: window) } ?? []
            self.detail = Self.detail(pattern, segment: segment, track: track)
        }

        /// Across the Pattern's own steps, whatever its length: the rule under it says that.
        private static func thumbnail(_ segment: Segment, window: PitchWindow) -> [NoteMark] {
            guard segment.stepCount > 0 else { return [] }
            let inset = AppLayout.thumbnailInset
            let width = AppLayout.cellWidth - 2 * inset
            let height = AppLayout.cellHeight - 2 * inset - AppLayout.lengthRuleHeight
            return segment.notes.map {
                let mark = NoteMark(
                    $0, step: width / CGFloat(segment.stepCount), width: width, height: height,
                    markHeight: AppLayout.thumbnailMarkHeight, window: window)
                return NoteMark(x: inset + mark.x, width: mark.width, y: inset + mark.y)
            }
        }

        private static func detail(
            _ pattern: Int, segment: Segment?, track: SegmentedTrack?
        ) -> String {
            guard let segment, let track else { return "Pattern \(pattern) — empty" }
            var detail = "Pattern \(pattern) — \(counted(segment.stepCount, "step"))"
            // Only a split run has somewhere to resume from, and that is what makes it worth saying.
            if track.isSplit {
                detail += ", steps \(segment.firstStep)-\(segment.lastStep) of the run"
            }
            return detail
        }
    }

    struct Row: Equatable {
        /// 1-4.
        let track: Int
        let name: String
        /// The well: the first Pattern the plan fills, or `--` where it fills none.
        let readout: String
        let isDrum: Bool
        /// The row label's tooltip.
        let detail: String
        let cells: [Cell]
        let runs: [AppLayout.Rail]
        let isEmpty: Bool

        init(track: Int, plan: SegmentedTrack?) {
            let byPattern = Dictionary(
                (plan?.segments ?? []).map { ($0.pattern, $0) },
                uniquingKeysWith: { first, _ in
                    first
                })
            self.track = track
            self.name = "Track \(track)"
            self.readout = patternReadout(plan?.segments.first?.pattern)
            self.isDrum = plan?.isDrum ?? false
            self.detail = Self.detail(plan)
            // One window for the whole run, so the halves of a split meet at the same height.
            let window = PitchWindow((plan?.segments ?? []).flatMap { $0.notes.map(\.pitch) })
            self.cells = (1...AppLayout.columnCount).map {
                Cell(pattern: $0, segment: byPattern[$0], track: plan, window: window)
            }
            self.runs = Self.runs(in: plan?.patterns ?? [])
            self.isEmpty = plan?.segments.isEmpty ?? true
        }

        private static func detail(_ plan: SegmentedTrack?) -> String {
            guard let plan, !plan.segments.isEmpty else { return "empty" }
            var parts: [String] = []
            if let source = plan.sourceTrack { parts.append("Source track \(source)") }
            if plan.isDrum { parts.append("drum") }
            parts.append(counted(plan.noteCount, plan.isDrum ? "trigger" : "note"))
            parts.append(located(plan.patterns))
            parts.append("\(counted(plan.stepCount, "step")) in all")
            return parts.joined(separator: " · ")
        }

        /// Neighbouring columns only. The planner splits into consecutive patterns, but a rail
        /// drawn across a gap would claim a run that is not there.
        private static func runs(in patterns: [Int]) -> [AppLayout.Rail] {
            let held = Set(patterns.filter { (1...AppLayout.columnCount).contains($0) })
            return AppLayout.rails(joining: held.filter { held.contains($0 + 1) })
        }
    }

    let header: String
    let columns: [Int]
    let rows: [Row]

    init(_ summary: SegmentationSummary) {
        let byTrack = Dictionary(
            summary.tracks.map { ($0.deviceTrack, $0) }, uniquingKeysWith: { first, _ in first })
        let filled = summary.tracks.filter { !$0.segments.isEmpty }
        self.header =
            counted(filled.count, "track") + " · "
            + counted(filled.reduce(0) { $0 + $1.segments.count }, "pattern")
        self.columns = Array(1...AppLayout.columnCount)
        self.rows = (1...Constants.trackItemIDs.count).map { Row(track: $0, plan: byTrack[$0]) }
    }

    /// Where the planner put each source track, keyed by source track, for the destination pickers
    /// to show as their automatic answer rather than working one out of their own.
    static func placements(_ summary: SegmentationSummary) -> [Int: String] {
        var devices: [Int: [Int]] = [:]
        for track in summary.tracks {
            guard let source = track.sourceTrack else { continue }
            devices[source, default: []].append(track.deviceTrack)
        }
        var placements = devices.mapValues { tracks -> String in
            let sorted = tracks.sorted()
            return sorted.count == 1
                ? "Track \(sorted[0])"
                : "Tracks " + sorted.map(String.init).joined(separator: ", ")
        }
        // A source track that only partly fits keeps the answer for the part that did.
        for source in summary.unplaced where placements[source.sourceTrack] == nil {
            placements[source.sourceTrack] = "dropped"
        }
        return placements
    }
}
