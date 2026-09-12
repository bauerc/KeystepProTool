import Foundation
import KSPKit
import KSPRun

struct SourceTrackList: Equatable {
    enum Badge: Equatable {
        case drums
        case percussion
        case tempo

        var text: String {
            switch self {
            case .drums: return "Drums"
            case .percussion: return "Percussion"
            case .tempo: return "Tempo"
            }
        }
    }

    struct Row: Equatable {
        let number: Int
        let name: String
        let badge: Badge?
        let channels: String
        let counts: String
        let isEmpty: Bool
        let detail: String
        let spoken: String

        init(_ track: SourceTrackSummary, badge: Badge?, drums: DrumSense) {
            let channels = track.channels.map(String.init).joined(separator: ", ")
            let counts =
                track.isEmpty
                ? "no notes"
                : "\(counted(track.noteCount, "note")) · \(counted(track.bars, "bar"))"
            self.number = track.number
            self.name = sourceTrackName(track)
            self.badge = badge
            self.channels = track.channels.isEmpty ? "—" : "ch " + channels
            self.counts = counts
            self.isEmpty = track.isEmpty
            self.detail = Self.detail(track, badge: badge, drums: drums)
            self.spoken = aloud(
                [
                    "Source track \(track.number)", track.name.isEmpty ? nil : track.name,
                    badge?.text,
                    track.channels.isEmpty
                        ? nil
                        : "channel\(track.channels.count == 1 ? "" : "s") "
                            + listed(track.channels.map(String.init)),
                    counts,
                ].compactMap { $0 }.joined(separator: " · "))
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
            case .tempo, nil:
                break
            }
            if track.channels.count > 1 {
                detail +=
                    badge == .drums && drums.designation.sourceTrack != nil
                    ? " Its channels are merged onto that one device track."
                    : " Each channel becomes a device track of its own."
            }
            return detail
        }
    }

    let header: String
    let rows: [Row]
    let collapsedNote: String?
    let allNotes: String?

    func note(verbose: Bool) -> String? { verbose ? allNotes : collapsedNote }

    init(_ summary: SongSummary, drums: DrumSense, selection: SourceTrackSelection) {
        self.header =
            "\(Arithmetic.general(summary.tempoBPM)) BPM · "
            + "\(Arithmetic.general(summary.beatsPerBar)) beats to the bar · "
            + counted(summary.tracks.count, "source track")
        let source = selection.drumSource(drums)
        self.rows = summary.tracks.map { track in
            if track.number == source { return Row(track, badge: .drums, drums: drums) }
            if track.isConductor { return Row(track, badge: .tempo, drums: drums) }
            let percussion = drums.designation == .auto && track.channels.contains(drums.channel)
            return Row(track, badge: percussion ? .percussion : nil, drums: drums)
        }
        self.collapsedNote = Self.note(summary.diagnostics.render(verbose: false))
        self.allNotes = Self.note(summary.diagnostics.render(verbose: true))
    }

    private static func note(_ lines: [String]) -> String? {
        lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

func sourceTrackName(_ track: SourceTrackSummary) -> String {
    track.name.isEmpty ? "Track \(track.number)" : track.name
}
