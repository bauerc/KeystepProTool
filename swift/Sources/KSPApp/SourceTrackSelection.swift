import Foundation
import KSPKit
import KSPRun

/// The tick and the destination per source track of a dropped MIDI file, and what the two come to
/// against the four tracks the device has.
struct SourceTrackSelection: Sendable, Equatable {
    /// Where one source track goes. ``automatic`` is the fill-upwards rule the planner applies
    /// unaided, and ``skip`` is the untick under the name the picker gives it.
    enum Destination: Hashable, Identifiable, Sendable {
        case automatic
        case track(Int)
        case drums
        case skip

        var id: Self { self }

        /// The device track it claims, or `nil` where the planner is left to decide.
        var device: Int? {
            switch self {
            case .automatic, .skip: return nil
            case .track(let number): return number
            case .drums: return 1
            }
        }

        var label: String {
            switch self {
            case .automatic: return "Automatic"
            case .track(let number): return "Track \(number)"
            case .drums: return "Drums"
            case .skip: return "Skip"
            }
        }
    }

    /// Every choice a picker offers, in menu order.
    static let destinations: [Destination] =
        [.automatic] + (1...Constants.trackItemIDs.count).map(Destination.track) + [.drums, .skip]

    private let tracks: [SourceTrackSummary]
    private var ticked: Set<Int>
    /// Only the tracks placed by hand; ``automatic`` and ``skip`` are read off the ticks instead.
    private var chosen: [Int: Destination]

    init() {
        self.tracks = []
        self.ticked = []
        self.chosen = [:]
    }

    /// The first four holding notes, which is the set `--midi-tracks 1,2,3,4` reads.
    init(_ summary: SongSummary) {
        self.tracks = summary.tracks
        self.ticked = Set(
            summary.tracks.filter { !$0.isEmpty }
                .prefix(Constants.trackItemIDs.count).map(\.number))
        self.chosen = [:]
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

    func destination(_ number: Int) -> Destination {
        guard ticked.contains(number) else { return .skip }
        return chosen[number] ?? .automatic
    }

    /// Anything but ``Destination/skip`` ticks the track: a destination is somewhere to import it
    /// to. A skipped track keeps its choice, so ticking it again restores what it was set to.
    mutating func send(_ number: Int, to destination: Destination) {
        switch destination {
        case .skip:
            ticked.remove(number)
        case .automatic:
            ticked.insert(number)
            chosen[number] = nil
        case .track, .drums:
            ticked.insert(number)
            chosen[number] = destination
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
        // Refused by the run rather than resolved by it, so it must not reach the runner at all.
        if let clash { return clash }
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

    /// `--route` as the CLI spells it, naming only the tracks placed by hand. A track left on
    /// ``Destination/automatic`` is deliberately unrouted: routing one merges its channels onto a
    /// single device track, which would move tracks nobody touched.
    var routeSpec: String? {
        let pairs = placed.compactMap { number -> String? in
            guard case .track(let device) = chosen[number] else { return nil }
            return "\(number):\(device)"
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: ",")
    }

    /// `--drum-track`; `nil` leaves the reader's own channel 10 detection standing.
    var drumTrack: Int? { placed.first { chosen[$0] == .drums } }

    /// The ticked tracks placed by hand, in source order.
    private var placed: [Int] { chosen.keys.filter(ticked.contains).sorted() }

    /// The ticked track the import will write as drums: the one set to ``Destination/drums``, or
    /// the one the reader found on channel 10, which is where the assignment looks when no option
    /// names one.
    private var drumSource: Int? {
        drumTrack ?? tracks.first { ticked.contains($0.number) && $0.isDrumTrack }?.number
    }

    /// A destination the run would refuse rather than resolve, named before it can reach the run.
    private var clash: String? {
        var holder: [Int: Int] = [:]
        for number in placed {
            guard let device = chosen[number]?.device else { continue }
            if let first = holder[device] {
                return "Source tracks \(first) and \(number) are both sent to "
                    + "\(Destination.track(device).label); one device track holds one source track."
            }
            holder[device] = number
        }
        guard let drums = drumSource else { return nil }
        for number in placed {
            guard let device = chosen[number]?.device else { continue }
            if number == drums && device != 1 {
                return "Source track \(drums) is the drum track, so it can only go to "
                    + "\(Destination.track(1).label); only device track 1 carries a drum set."
            }
            if number != drums && device == 1 {
                return "Source track \(number) is sent to \(Destination.track(1).label), which "
                    + "source track \(drums) holds as the drum track; only device track 1 carries "
                    + "a drum set."
            }
        }
        return nil
    }

    /// One per channel of a ticked track: `apply` fills the device's tracks with clips, and a
    /// source track carrying several channels gives up one apiece. A track placed by hand is the
    /// exception -- naming it merges its channels onto the one device track it was sent to.
    private var demand: Int {
        tracks.filter { ticked.contains($0.number) }
            .reduce(0) { $0 + (chosen[$1.number] == nil ? $1.channels.count : 1) }
    }

    private var dropped: [SourceTrackSummary] {
        tracks.filter { !ticked.contains($0.number) && !$0.isEmpty }
    }
}
