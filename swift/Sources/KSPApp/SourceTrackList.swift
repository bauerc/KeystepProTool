import Foundation
import KSPKit
import KSPRun

/// The preview list: one row per source track of a dropped MIDI file, in the file's own order.
struct SourceTrackList: Equatable {
    static let legend =
        "Untick a source track to leave it out. Counts are the notes in the file. Hover a "
        + "track for what it becomes."

    enum Badge: Equatable {
        case drums
        case percussion

        /// ``drums`` says what the app calls the destination elsewhere.
        var text: String {
            switch self {
            case .drums: return "Drums"
            case .percussion: return "Percussion"
            }
        }
    }

    struct Row: Equatable {
        /// Counting from 1 over every track of the file, as `--midi-tracks` counts them.
        let number: Int
        let name: String
        /// `nil` on a track the import reads melodically.
        let badge: Badge?
        let channels: String
        let counts: String
        let isEmpty: Bool
        /// The row's tooltip.
        let detail: String

        init(_ track: SourceTrackSummary, badge: Badge?) {
            self.number = track.number
            self.name = sourceTrackName(track)
            self.badge = badge
            self.channels =
                track.channels.isEmpty
                ? "—" : "ch " + track.channels.map(String.init).joined(separator: ", ")
            self.counts =
                track.isEmpty
                ? "no notes"
                : "\(counted(track.noteCount, "note")) · \(counted(track.bars, "bar"))"
            self.isEmpty = track.isEmpty
            self.detail = Self.detail(track, badge: badge)
        }

        private static func detail(_ track: SourceTrackSummary, badge: Badge?) -> String {
            guard !track.isEmpty else {
                return
                    "Source track \(track.number) holds no notes, so nothing is imported from it."
            }
            let channels =
                track.channels.count == 1
                ? "channel \(track.channels[0])"
                : "channels " + track.channels.map(String.init).joined(separator: ", ")
            var detail =
                "Source track \(track.number) — \(counted(track.noteCount, "note")) over "
                + "\(counted(track.bars, "bar")) on \(channels)."
            switch badge {
            case .drums:
                // Only the channel 10 part of a split track is the drum track; the badge alone
                // would claim the whole row.
                detail +=
                    track.channels.count == 1
                    ? " Channel 10 is where the import looks for drums, so this one becomes "
                        + "the drum track."
                    : " Channel 10 is where the import looks for drums, so that part of this "
                        + "one becomes the drum track."
            case .percussion:
                detail +=
                    " Channel 10 is where the import looks for drums, but the device has "
                    + "one drum track, so this one is imported melodically."
            case nil:
                break
            }
            if track.channels.count > 1 {
                detail += " Each channel becomes a device track of its own."
            }
            return detail
        }
    }

    let header: String
    let rows: [Row]
    /// What the read found; `nil` where it found nothing. Rendered once in both modes, as
    /// ``Outcome`` renders its findings: a SwiftUI body is re-evaluated far more often than a file
    /// is read, and the sidebar's toggle reaches this note as it reaches those.
    let collapsedNote: String?
    let allNotes: String?

    func note(verbose: Bool) -> String? { verbose ? allNotes : collapsedNote }

    init(_ summary: SongSummary) {
        self.header =
            "\(Arithmetic.general(summary.tempoBPM)) BPM · "
            + "\(Arithmetic.general(summary.beatsPerBar)) beats to the bar · "
            + counted(summary.tracks.count, "source track")
        // The drum track is the reader's to name, not this view's to re-derive: it is decided over
        // channels, where the import decides it, rather than over whole tracks.
        self.rows = summary.tracks.map { track in
            if track.isDrumTrack { return Row(track, badge: .drums) }
            return Row(track, badge: track.isPercussion ? .percussion : nil)
        }
        self.collapsedNote = Self.note(summary.diagnostics.render(verbose: false))
        self.allNotes = Self.note(summary.diagnostics.render(verbose: true))
    }

    private static func note(_ lines: [String]) -> String? {
        lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// What the file calls a track, or its number where it names none.
func sourceTrackName(_ track: SourceTrackSummary) -> String {
    track.name.isEmpty ? "Track \(track.number)" : track.name
}

private func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}
