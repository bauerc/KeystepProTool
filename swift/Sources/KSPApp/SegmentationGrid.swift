import Foundation
import KSPKit
import KSPRun

/// What the import would lay down, drawn as the export grid is: four device tracks down, sixteen
/// pattern slots across. Every figure comes from the planner; this only arranges them.
struct SegmentationGrid: Equatable {
    static let legend = "Counts are steps. Hover a slot for what it will hold."

    struct Cell: Equatable {
        /// 1-16.
        let pattern: Int
        let label: String
        let isEmpty: Bool
        let detail: String

        init(pattern: Int, segment: Segment?, track: SegmentedTrack?) {
            self.pattern = pattern
            self.label = segment.map { "\($0.stepCount)" } ?? "—"
            self.isEmpty = segment == nil
            self.detail = Self.detail(pattern, segment: segment, track: track)
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
            self.detail = Self.detail(plan)
            self.cells = (1...AppLayout.columnCount).map {
                Cell(pattern: $0, segment: byPattern[$0], track: plan)
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

        /// Worded as `convert` words it, so the preview and the result read alike.
        private static func located(_ patterns: [Int]) -> String {
            guard let first = patterns.first, let last = patterns.last else { return "no pattern" }
            return patterns.count == 1 ? "pattern \(first)" : "patterns \(first)-\(last)"
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
    /// What will not survive the import, said before it runs.
    let warnings: [String]

    init(_ summary: SegmentationSummary) {
        let byTrack = Dictionary(
            summary.tracks.map { ($0.deviceTrack, $0) }, uniquingKeysWith: { first, _ in first })
        let filled = summary.tracks.filter { !$0.segments.isEmpty }
        self.header =
            counted(filled.count, "track") + " · "
            + counted(filled.reduce(0) { $0 + $1.segments.count }, "pattern")
        self.columns = Array(1...AppLayout.columnCount)
        self.rows = (1...Constants.trackItemIDs.count).map { Row(track: $0, plan: byTrack[$0]) }
        self.warnings = Self.warnings(summary)
    }

    private static func warnings(_ summary: SegmentationSummary) -> [String] {
        var warnings = summary.unplaced.map { source -> String in
            guard source.isWhole else {
                // Which channel goes is the planner's to say, not this view's to guess.
                return "Source track \(source.sourceTrack) carries "
                    + "\(counted(source.parts, "channel")) and only \(source.placedParts) fit; "
                    + "\(counted(source.droppedParts, "channel")) would be dropped."
            }
            return "Source track \(source.sourceTrack) will not fit; the device has "
                + "\(Constants.trackItemIDs.count) tracks, so its "
                + "\(counted(source.noteCount, "note")) would be dropped."
        }
        for track in summary.tracks where track.droppedPatterns > 0 {
            warnings.append(
                "Track \(track.deviceTrack) runs past pattern \(Constants.patternsPerTrack); "
                    + "\(counted(track.droppedPatterns, "pattern")) of its tail would be dropped.")
        }
        return warnings
    }
}
