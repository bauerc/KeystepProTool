import Foundation
import KSPKit
import KSPRun

/// The preview list: one row per source track of a dropped MIDI file, in the file's own order.
struct SourceTrackList: Equatable {
    static let legend =
        "Untick a source track to leave it out, or send it to a device track of your own "
        + "choosing. Counts are the notes in the file. Hover a track for what it becomes."

    enum Badge: Equatable {
        case drums
        case percussion
        case tempo

        /// ``drums`` says what the app calls the destination elsewhere; ``tempo`` says what a DAW
        /// calls the track the repo's own exporter writes as the conductor.
        var text: String {
            switch self {
            case .drums: return "Drums"
            case .percussion: return "Percussion"
            case .tempo: return "Tempo"
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

        init(_ track: SourceTrackSummary, badge: Badge?, drums: DrumSense) {
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
            self.detail = Self.detail(track, badge: badge, drums: drums)
        }

        private static func detail(_ track: SourceTrackSummary, badge: Badge?, drums: DrumSense)
            -> String
        {
            guard !track.isEmpty else {
                guard track.isConductor else {
                    return
                        "Source track \(track.number) holds no notes, so nothing is imported "
                        + "from it."
                }
                return
                    "Source track \(track.number) carries the file's tempo and time signature, "
                    + "not notes, so nothing is imported from it."
            }
            let channels =
                track.channels.count == 1
                ? "channel \(track.channels[0])"
                : "channels " + track.channels.map(String.init).joined(separator: ", ")
            var detail =
                "Source track \(track.number) — \(counted(track.noteCount, "note")) over "
                + "\(counted(track.bars, "bar")) on \(channels)."
            switch badge {
            case .drums where drums.designation.sourceTrack != nil:
                detail += " This one is sent to Drums, so it becomes the drum track."
            case .drums:
                // Only the searched channel's part of a split track is the drum track; the badge
                // alone would claim the whole row.
                detail +=
                    track.channels.count == 1
                    ? " Channel \(drums.channel) is where the import looks for drums, so this one "
                        + "becomes the drum track."
                    : " Channel \(drums.channel) is where the import looks for drums, so that part "
                        + "of this one becomes the drum track."
            case .percussion:
                detail +=
                    " Channel \(drums.channel) is where the import looks for drums, but the device "
                    + "has one drum track, so this one is imported melodically."
            // A conductor track holds no notes, so it returned above rather than reaching here.
            case .tempo, nil:
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

    init(_ summary: SongSummary, drums: DrumSense) {
        self.header =
            "\(Arithmetic.general(summary.tempoBPM)) BPM · "
            + "\(Arithmetic.general(summary.beatsPerBar)) beats to the bar · "
            + counted(summary.tracks.count, "source track")
        // `isDrumTrack` and `isPercussion` are GM's reading of the file, so under any designation
        // but the default they would badge a row the import will not touch. Derived off `channels`
        // instead: the first track carrying the searched channel is the one `assign` reaches first.
        let searched = summary.tracks.filter { $0.channels.contains(drums.channel) }.map(\.number)
        let source =
            drums.designation.sourceTrack ?? (drums.designation == .auto ? searched.first : nil)
        self.rows = summary.tracks.map { track in
            if track.number == source { return Row(track, badge: .drums, drums: drums) }
            if track.isConductor { return Row(track, badge: .tempo, drums: drums) }
            let percussion = drums.designation == .auto && searched.contains(track.number)
            return Row(track, badge: percussion ? .percussion : nil, drums: drums)
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
