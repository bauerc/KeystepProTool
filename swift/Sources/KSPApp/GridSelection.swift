import Foundation
import KSPRun

struct GridSelection: Sendable, Equatable {
    static let legend = "Click a slot, a track name or a slot number to leave it out of the export."

    struct Cell: Sendable, Hashable {
        let track: Int
        let pattern: Int
    }

    enum Tick: Sendable, Equatable {
        case on
        case off
        case mixed
    }

    private let tracks: [Int]
    private let names: [Int: String]
    private let patterns: [Int]
    /// The unticked cells, so a fresh selection is empty and everything starts on.
    private var unticked: Set<Cell> = []

    init() {
        self.tracks = []
        self.names = [:]
        self.patterns = []
    }

    init(_ summary: ProjectSummary) {
        self.tracks = summary.tracks.map(\.number)
        // Deduplicated rather than trusted unique: the reader hands over whatever the file holds.
        self.names = Dictionary(
            summary.tracks.map { ($0.number, $0.name) }, uniquingKeysWith: { first, _ in first })
        self.patterns = Array(1...AppLayout.columnCount)
    }

    var isInert: Bool { tracks.isEmpty || patterns.isEmpty }

    func isTicked(track: Int, pattern: Int) -> Bool {
        !unticked.contains(Cell(track: track, pattern: pattern))
    }

    /// Read across the slots in play, so a slot off everywhere leaves no row reading as half-ticked.
    func state(ofTrack track: Int) -> Tick {
        state(of: livePatterns.map { Cell(track: track, pattern: $0) })
    }

    func state(ofPattern pattern: Int) -> Tick {
        state(of: liveTracks.map { Cell(track: $0, pattern: pattern) })
    }

    func isTicked(track: Int) -> Bool { state(ofTrack: track) == .on }

    func isTicked(pattern: Int) -> Bool { state(ofPattern: pattern) == .on }

    mutating func toggle(track: Int, pattern: Int) {
        let cell = Cell(track: track, pattern: pattern)
        if unticked.contains(cell) {
            unticked.remove(cell)
        } else {
            unticked.insert(cell)
        }
    }

    /// Ticking reaches only the slots in play, so bringing a track back does not undo a column.
    mutating func toggle(track: Int) {
        let ticked = state(ofTrack: track) != .on
        let reached = ticked ? livePatterns : patterns
        set(reached.map { Cell(track: track, pattern: $0) }, ticked: ticked)
    }

    mutating func toggle(pattern: Int) {
        let ticked = state(ofPattern: pattern) != .on
        let reached = ticked ? liveTracks : tracks
        set(reached.map { Cell(track: $0, pattern: pattern) }, ticked: ticked)
    }

    /// The ticked slots per track, empty when everything is -- how the runner spells "all".
    var selectedCells: [Int: Set<Int>] {
        guard !unticked.isEmpty else { return [:] }
        var selected: [Int: Set<Int>] = [:]
        for track in tracks {
            let ticked = patterns.filter { isTicked(track: track, pattern: $0) }
            if !ticked.isEmpty { selected[track] = Set(ticked) }
        }
        return selected
    }

    var blockReason: String? {
        guard !isInert, !unticked.isEmpty, selectedCells.isEmpty else { return nil }
        return "Nothing is ticked. Tick at least one pattern slot to convert."
    }

    /// What the result says was left out, widest grouping first.
    var exclusionNote: String? {
        guard !isInert, !unticked.isEmpty else { return nil }
        let live = liveTrackNumbers
        var parts = [
            live.count == tracks.count
                ? nil : tracks.filter { !live.contains($0) }.map(name).joined(separator: ", ")
        ]

        let everywhere = patterns.filter { pattern in
            !live.isEmpty && live.allSatisfy { !isTicked(track: $0, pattern: pattern) }
        }
        parts.append(everywhere.isEmpty ? nil : "pattern \(slots(everywhere))")

        for track in live {
            let rest = patterns.filter {
                !everywhere.contains($0) && !isTicked(track: track, pattern: $0)
            }
            parts.append(rest.isEmpty ? nil : "\(name(track)) \(slots(rest))")
        }

        let listed = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return listed.isEmpty ? nil : "Excluded: " + listed.joined(separator: " · ")
    }

    func name(_ track: Int) -> String { names[track] ?? "Track \(track)" }

    private func slots(_ numbers: [Int]) -> String {
        "slot\(numbers.count == 1 ? "" : "s") " + numbers.map(String.init).joined(separator: ", ")
    }

    private var liveTrackNumbers: [Int] {
        tracks.filter { track in patterns.contains { isTicked(track: track, pattern: $0) } }
    }

    /// Nothing ticked puts the whole grid back in play, or a click would reach nothing.
    private var liveTracks: [Int] {
        let live = liveTrackNumbers
        return live.isEmpty ? tracks : live
    }

    private var livePatterns: [Int] {
        let live = patterns.filter { pattern in
            tracks.contains { isTicked(track: $0, pattern: pattern) }
        }
        return live.isEmpty ? patterns : live
    }

    private func state(of cells: [Cell]) -> Tick {
        let ticked = cells.count(where: { !unticked.contains($0) })
        if ticked == cells.count { return .on }
        return ticked == 0 ? .off : .mixed
    }

    private mutating func set(_ cells: [Cell], ticked: Bool) {
        if ticked {
            unticked.subtract(cells)
        } else {
            unticked.formUnion(cells)
        }
    }
}
