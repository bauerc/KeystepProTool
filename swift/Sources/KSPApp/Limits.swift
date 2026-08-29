import Foundation
import KSPKit
import KSPRun

/// How close the planned import comes to each of the device's five walls, read off the plan the
/// conversion would run on and the refusals the planner raised against it.
struct Limits: Equatable {
    static let heading = "Against the device's limits"
    /// Amber from three quarters of the way to the wall up to but not including the wall itself,
    /// on all five alike.
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
        /// What the planner refused. "Warning", not "note": a note is a melodic event (ADR 0001).
        let warnings: [String]

        var id: String { name }

        var figure: String { "\(used) / \(limit)" }

        init(_ name: String, used: Int, limit: Int, site: String? = nil, warnings: [String] = []) {
            self.name = name
            self.used = used
            self.limit = limit
            self.site = site
            self.warnings = warnings
            self.status = Self.status(used: used, limit: limit, refused: !warnings.isEmpty)
        }

        /// The planner truncates to the limit, so a figure at the wall has not passed it: only a
        /// refusal says a limit was exceeded. Nor is a figure *on* the wall approaching one -- 64
        /// of 64 steps is the device's stated capability being used, and amber over what the
        /// device is for reads as a fault where there is none.
        private static func status(used: Int, limit: Int, refused: Bool) -> Status {
            if refused { return .over }
            guard limit > 0, used < limit, Double(used) / Double(limit) >= Limits.nearThreshold
            else {
                return .within
            }
            return .near
        }
    }

    /// One pattern and the track it sits on, which every per-pattern figure is found at.
    fileprivate struct Placed {
        let track: SegmentedTrack
        let segment: Segment

        var site: String { "Track \(track.deviceTrack), pattern \(segment.pattern)" }
    }

    let gauges: [Gauge]

    var exceeded: [Gauge] { gauges.filter { $0.status == .over } }

    init(_ summary: SegmentationSummary) {
        let filled = summary.tracks.filter { !$0.segments.isEmpty }
        let placed = filled.flatMap { track in
            track.segments.map { Placed(track: track, segment: $0) }
        }

        let furthest = filled.max { reach($0) < reach($1) }
        let longest = placed.max { $0.segment.stepCount < $1.segment.stepCount }
        let fullest = placed.max { $0.segment.noteCount < $1.segment.noteCount }
        let busiest = placed.max { $0.segment.mostNotesOnAStep < $1.segment.mostNotesOnAStep }

        self.gauges = [
            // Counted, not reached: routing can pin a source to one track and leave the rest free.
            Gauge(
                "Tracks", used: filled.count, limit: Constants.trackItemIDs.count,
                warnings: summary.unplaced.map(unplacedWarning)),
            Gauge(
                "Patterns per track", used: furthest.map(reach) ?? 0,
                limit: Constants.patternsPerTrack,
                site: furthest.map { "Track \($0.deviceTrack)" },
                warnings: filled.filter { $0.droppedPatterns > 0 }.map(droppedTailWarning)),
            Gauge(
                "Steps per pattern", used: longest?.segment.stepCount ?? 0,
                limit: Constants.maxSteps, site: longest?.site),
            Gauge(
                "Notes per pattern", used: fullest?.segment.noteCount ?? 0,
                limit: Constants.poolCapacity, site: fullest?.site,
                warnings: placed.filter { $0.segment.droppedNotes > 0 }.map(overflowWarning)),
            Gauge(
                "Notes per step", used: busiest?.segment.mostNotesOnAStep ?? 0,
                limit: Constants.maxNotesPerStep, site: busiest?.site),
        ]
    }
}

/// The pattern a run reaches, not the number it fills: a run starting at pattern 14 has three
/// slots left whatever it holds.
private func reach(_ track: SegmentedTrack) -> Int {
    track.patterns.max() ?? 0
}

private func unplacedWarning(_ source: UnplacedSource) -> String {
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

private func droppedTailWarning(_ track: SegmentedTrack) -> String {
    "Track \(track.deviceTrack) runs past pattern \(Constants.patternsPerTrack); "
        + "\(counted(track.droppedPatterns, "pattern")) of its tail would be dropped."
}

private func overflowWarning(_ placed: Limits.Placed) -> String {
    "\(placed.site) holds more than the \(Constants.poolCapacity) notes a pattern pools; the "
        + "last \(counted(placed.segment.droppedNotes, "note")) would be dropped."
}
