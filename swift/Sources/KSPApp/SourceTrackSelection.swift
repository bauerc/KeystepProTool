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

    /// Every track sent to Drums, not just the first: two is a state the picker allows and
    /// ``clash(_:)`` reports, and a skipped one keeps its choice, so clearing must take them all
    /// or the sidebar's row snaps back to the one left behind.
    mutating func clearDrums() {
        for (number, destination) in chosen where destination == .drums { chosen[number] = nil }
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

    func blockReason(_ drums: DrumSense) -> String? {
        guard !isInert else { return nil }
        if ticked.isEmpty { return "Nothing is ticked. Tick at least one source track to convert." }
        // Refused by the run rather than resolved by it, so it must not reach the runner at all.
        if let clash = clash(drums) { return clash }
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

    /// `--route` as the CLI spells it, naming only the tracks placed by hand: routing one merges
    /// its channels onto a single device track, which would move tracks nobody touched.
    var routeSpec: String? {
        let pairs = placed.compactMap { number -> String? in
            guard case .track(let device) = chosen[number] else { return nil }
            return "\(number):\(device)"
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: ",")
    }

    /// `--drum-track`; `nil` leaves the sidebar's own designation standing.
    var drumTrack: Int? { placed.first { chosen[$0] == .drums } }

    /// The ticked tracks placed by hand, in source order.
    private var placed: [Int] { chosen.keys.filter(ticked.contains).sorted() }

    /// The ticked track the import will write as drums. Under `auto` the fallback is the first
    /// ticked track on the searched channel rather than the reader's `isDrumTrack`, which names the
    /// first over the whole file: the assignment looks among the clips actually read, so skipping
    /// one promotes the next.
    func drumSource(_ drums: DrumSense) -> Int? {
        switch drums.designation {
        case .source(let number): return number
        case .none: return nil
        case .auto:
            return tracks.first {
                ticked.contains($0.number) && $0.channels.contains(drums.channel)
            }?.number
        }
    }

    /// A destination the run would refuse rather than resolve, named before it can reach the run.
    private func clash(_ drums: DrumSense) -> String? {
        var holder: [Int: Int] = [:]
        for number in placed {
            guard let device = chosen[number]?.device else { continue }
            if let first = holder[device] {
                // Named as they were chosen: two tracks set to Drums did not ask for "Track 1".
                let sent = chosen[first] == chosen[number] ? chosen[number] : .track(device)
                return "Source tracks \(first) and \(number) are both sent to "
                    + "\(sent?.label ?? Destination.track(device).label); one device track holds "
                    + "one source track."
            }
            holder[device] = number
        }
        guard let source = drumSource(drums) else { return nil }
        for number in placed {
            guard let device = chosen[number]?.device else { continue }
            if number == source && device != 1 {
                return "Source track \(source) is the drum track, so it can only go to "
                    + "\(Destination.track(1).label); only device track 1 carries a drum set."
            }
            if number != source && device == 1 {
                return "Source track \(number) is sent to \(Destination.track(1).label), which "
                    + "source track \(source) holds as the drum track; only device track 1 carries "
                    + "a drum set."
            }
        }
        return nil
    }

    /// One per channel of a ticked track: `apply` fills the device's tracks with clips. A track
    /// placed by hand asks for one — naming it merges its channels onto the track it was sent to.
    private var demand: Int {
        tracks.filter { ticked.contains($0.number) }
            .reduce(0) { $0 + (chosen[$1.number] == nil ? $1.channels.count : 1) }
    }

    private var dropped: [SourceTrackSummary] {
        tracks.filter { !ticked.contains($0.number) && !$0.isEmpty }
    }
}
