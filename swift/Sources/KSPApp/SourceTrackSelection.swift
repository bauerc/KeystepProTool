import Foundation
import KSPKit
import KSPRun

struct SourceTrackSelection: Sendable, Equatable {
    enum Destination: Hashable, Identifiable, Sendable {
        case automatic
        case track(Int)
        case drums
        case skip

        var id: Self { self }

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

    static let destinations: [Destination] =
        [.automatic] + (1...Constants.trackItemIDs.count).map(Destination.track) + [.drums, .skip]

    private let tracks: [SourceTrackSummary]
    private var ticked: Set<Int>
    private var chosen: [Int: Destination]

    init() {
        self.tracks = []
        self.ticked = []
        self.chosen = [:]
    }

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

    mutating func clearDrums() {
        for (number, destination) in chosen where destination == .drums { chosen[number] = nil }
    }

    var overflowNote: String? {
        let over = demand - Constants.trackItemIDs.count
        guard over > 0 else { return nil }
        return "That needs \(demand) device tracks, so \(over) would be dropped."
    }

    func blockReason(_ drums: DrumSense) -> String? {
        guard !isInert else { return nil }
        if ticked.isEmpty { return "Nothing is ticked. Tick at least one source track to convert." }
        if let clash = clash(drums) { return clash }
        guard demand == 0 else { return nil }
        return "No ticked source track holds notes, so nothing would be written."
    }

    var exclusionNote: String? {
        guard !dropped.isEmpty else { return nil }
        return "Excluded: " + dropped.map(sourceTrackName).joined(separator: ", ")
    }

    var spec: String? {
        guard !ticked.isEmpty, !dropped.isEmpty else { return nil }
        return ticked.sorted().map(String.init).joined(separator: ",")
    }

    var routeSpec: String? {
        let pairs = placed.compactMap { number -> String? in
            guard case .track(let device) = chosen[number] else { return nil }
            return "\(number):\(device)"
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: ",")
    }

    var drumTrack: Int? { placed.first { chosen[$0] == .drums } }

    private var placed: [Int] { chosen.keys.filter(ticked.contains).sorted() }

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

    private func clash(_ drums: DrumSense) -> String? {
        var holder: [Int: Int] = [:]
        for number in placed {
            guard let device = chosen[number]?.device else { continue }
            if let first = holder[device] {
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

    private var demand: Int {
        tracks.filter { ticked.contains($0.number) }
            .reduce(0) { $0 + (chosen[$1.number] == nil ? $1.channels.count : 1) }
    }

    private var dropped: [SourceTrackSummary] {
        tracks.filter { !ticked.contains($0.number) && !$0.isEmpty }
    }
}
