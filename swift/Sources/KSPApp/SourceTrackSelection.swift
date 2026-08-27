import Foundation
import KSPKit
import KSPRun

/// The tick per source track of a dropped MIDI file, and what the ticks come to against the four
/// tracks the device has.
struct SourceTrackSelection: Sendable, Equatable {
    private let tracks: [SourceTrackSummary]
    private var ticked: Set<Int>

    init() {
        self.tracks = []
        self.ticked = []
    }

    /// The first four holding notes, which is the set `--midi-tracks 1,2,3,4` reads.
    init(_ summary: SongSummary) {
        self.tracks = summary.tracks
        self.ticked = Set(
            summary.tracks.filter { !$0.isEmpty }
                .prefix(Constants.trackItemIDs.count).map(\.number))
    }

    var isInert: Bool { tracks.isEmpty }

    func isTicked(_ number: Int) -> Bool { ticked.contains(number) }

    mutating func toggle(_ number: Int) {
        if ticked.contains(number) {
            ticked.remove(number)
        } else {
            ticked.insert(number)
        }
    }

    var countLine: String? {
        guard !isInert else { return nil }
        return "\(ticked.count) of \(tracks.count) source track\(tracks.count == 1 ? "" : "s") "
            + "ticked; the device has \(Constants.trackItemIDs.count) tracks."
    }

    /// Said rather than refused: what a tick costs is a device track per channel, so no cap on the
    /// ticks themselves could be honest about what will fit.
    var overflowNote: String? {
        let over = demand - Constants.trackItemIDs.count
        guard over > 0 else { return nil }
        return "That needs \(demand) device tracks, so \(over) would be dropped."
    }

    var blockReason: String? {
        guard !isInert else { return nil }
        if ticked.isEmpty { return "Nothing is ticked. Tick at least one source track to convert." }
        // Left to Convert this reaches the runner and comes back as "no notes to convert".
        guard demand == 0 else { return nil }
        return "No ticked source track holds notes, so nothing would be written."
    }

    /// What the result says was left out. A track holding nothing goes unnamed: leaving one out
    /// changes nothing about the conversion.
    var exclusionNote: String? {
        guard !dropped.isEmpty else { return nil }
        return "Excluded: " + dropped.map(sourceTrackName).joined(separator: ", ")
    }

    /// `--midi-tracks` as the CLI spells it; `nil` where every track holding notes is ticked, which
    /// is the same conversion and leaves the runner's diagnostics reading as unselected.
    var spec: String? {
        guard !ticked.isEmpty, !dropped.isEmpty else { return nil }
        return ticked.sorted().map(String.init).joined(separator: ",")
    }

    /// One per channel of a ticked track: `apply` fills the device's tracks with clips, and a
    /// source track carrying several channels gives up one apiece.
    private var demand: Int {
        tracks.filter { ticked.contains($0.number) }.reduce(0) { $0 + $1.channels.count }
    }

    private var dropped: [SourceTrackSummary] {
        tracks.filter { !ticked.contains($0.number) && !$0.isEmpty }
    }
}
