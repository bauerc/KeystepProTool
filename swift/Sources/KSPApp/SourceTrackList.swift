import Foundation
import KSPKit
import KSPRun

/// The preview list: one row per source track of a dropped MIDI file, in the file's own order.
struct SourceTrackList: Equatable {
    static let legend = "Counts are the notes in the file. Hover a track for what it becomes."

    enum Badge: Equatable {
        case drums
        case percussion

        /// ``drums`` says what the app calls the destination elsewhere.
        var text: String { self == .drums ? "Drums" : "Percussion" }
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
            self.name = track.name.isEmpty ? "Track \(track.number)" : track.name
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
                detail +=
                    " Channel 10 is where the import looks for drums, so this one becomes "
                    + "the drum track."
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
    /// What the read found, collapsed to a line per kind; `nil` where it found nothing.
    let note: String?

    init(_ summary: SongSummary) {
        // Only the first: the device has one drum track, so a later percussion track is melodic.
        let drums = summary.tracks.first { $0.isPercussion && !$0.isEmpty }?.number
        self.header =
            "\(Arithmetic.general(summary.tempoBPM)) BPM · "
            + "\(Arithmetic.general(summary.beatsPerBar)) beats to the bar · "
            + counted(summary.tracks.count, "source track")
        self.rows = summary.tracks.map { track in
            guard track.isPercussion, !track.isEmpty else { return Row(track, badge: nil) }
            return Row(track, badge: track.number == drums ? .drums : .percussion)
        }
        let lines = summary.diagnostics.render(verbose: false)
        self.note = lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

private func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}
