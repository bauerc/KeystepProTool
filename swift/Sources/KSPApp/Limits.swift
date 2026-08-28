import Foundation
import KSPKit
import KSPRun

/// How close the planned import comes to each of the device's five walls. Every figure is read off
/// the plan the conversion would run on, and every refusal off the planner's own diagnostics --
/// which is the only way the two can agree.
struct Limits: Equatable {
    static let heading = "Against the device's limits"
    /// Amber from three quarters of the way to the wall, on all five alike.
    static let nearThreshold = 0.75

    enum Status: Equatable {
        case within
        case near
        case over
    }

    struct Gauge: Equatable, Identifiable {
        let name: String
        let used: Int
        let limit: Int
        let status: Status
        /// The track, and the pattern where there is one, the figure was found at. The track count
        /// is the whole plan's and names nowhere.
        let site: String?
        /// What the planner refused, where it refused anything.
        let notes: [String]

        var id: String { name }

        var figure: String { "\(used) / \(limit)" }

        init(_ name: String, used: Int, limit: Int, site: String? = nil, notes: [String] = []) {
            self.name = name
            self.used = used
            self.limit = limit
            self.site = site
            self.notes = notes
            self.status = Self.status(used: used, limit: limit, refused: !notes.isEmpty)
        }

        /// The planner truncates to the limit, so a figure at the wall has not passed it: only a
        /// refusal says a limit was exceeded.
        private static func status(used: Int, limit: Int, refused: Bool) -> Status {
            if refused { return .over }
            guard limit > 0, Double(used) / Double(limit) >= Limits.nearThreshold else {
                return .within
            }
            return .near
        }
    }

    let gauges: [Gauge]

    var exceeded: [Gauge] { gauges.filter { $0.status == .over } }

    init(_ summary: SegmentationSummary) {
        let filled = summary.tracks.filter { !$0.segments.isEmpty }
        let placed = filled.flatMap { track in track.segments.map { (track, $0) } }

        let furthest = filled.max { left, right in reach(left) < reach(right) }
        let longest = placed.max { $0.1.stepCount < $1.1.stepCount }
        let fullest = placed.max { $0.1.noteCount < $1.1.noteCount }
        let busiest = placed.max { $0.1.busiestStep < $1.1.busiestStep }

        self.gauges = [
            Gauge(
                "Tracks", used: filled.count, limit: Constants.trackItemIDs.count,
                notes: summary.unplaced.map(unplacedNote)),
            Gauge(
                "Patterns per track", used: furthest.map(reach) ?? 0,
                limit: Constants.patternsPerTrack, site: furthest.map { "Track \($0.deviceTrack)" },
                notes: filled.filter { $0.droppedPatterns > 0 }.map(droppedTailNote)),
            Gauge(
                "Steps per pattern", used: longest?.1.stepCount ?? 0, limit: Constants.maxSteps,
                site: longest.map(located)),
            Gauge(
                "Notes per pattern", used: fullest?.1.noteCount ?? 0, limit: Constants.poolCapacity,
                site: fullest.map(located),
                notes: placed.filter { $0.1.droppedNotes > 0 }.map(overflowNote)),
            Gauge(
                "Notes per step", used: busiest?.1.busiestStep ?? 0,
                limit: Constants.maxNotesPerStep, site: busiest.map(located)),
        ]
    }
}

/// The pattern a run reaches, not the number it fills: a run starting at pattern 14 has three
/// slots left whatever it holds.
private func reach(_ track: SegmentedTrack) -> Int {
    track.patterns.max() ?? 0
}

private func located(_ placed: (track: SegmentedTrack, segment: Segment)) -> String {
    "Track \(placed.track.deviceTrack), pattern \(placed.segment.pattern)"
}

private func unplacedNote(_ source: UnplacedSource) -> String {
    guard source.isWhole else {
        // Which channel goes is the planner's to say, not this view's to guess.
        return "Source track \(source.sourceTrack) carries \(counted(source.parts, "channel")) "
            + "and only \(source.placedParts) fit; "
            + "\(counted(source.droppedParts, "channel")) would be dropped."
    }
    return "Source track \(source.sourceTrack) will not fit; the device has "
        + "\(Constants.trackItemIDs.count) tracks, so its "
        + "\(counted(source.noteCount, "note")) would be dropped."
}

private func droppedTailNote(_ track: SegmentedTrack) -> String {
    "Track \(track.deviceTrack) runs past pattern \(Constants.patternsPerTrack); "
        + "\(counted(track.droppedPatterns, "pattern")) of its tail would be dropped."
}

private func overflowNote(_ placed: (track: SegmentedTrack, segment: Segment)) -> String {
    "\(located(placed)) holds more than the \(Constants.poolCapacity) notes a pattern pools; the "
        + "last \(counted(placed.segment.droppedNotes, "note")) would be dropped."
}
