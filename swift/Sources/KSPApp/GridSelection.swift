import Foundation
import KSPRun

/// Which of the grid's cells the export runs over. No SwiftUI, so the whole rule unit-tests.
///
/// `Project.select(tracks:patterns:)` keeps the **cross product** of the two sets, so the only
/// selection either core can express is a rectangle -- whole tracks against whole pattern slots.
/// Cells still tick freely, because a per-cell tick is what a user reaches for; a selection that is
/// not a rectangle turns Convert off through ``blockReason`` rather than being widened silently
/// into one the runner would accept.
struct GridSelection: Sendable, Equatable {
    /// What a click does, said under the grid -- a tick is not otherwise self-explanatory when
    /// everything starts ticked and so nothing looks like a control.
    ///
    /// The second sentence is not a nicety: `MIDIExport.arrange` lays the slots it is given end to
    /// end, so leaving one out closes the gap rather than leaving a silence where it was.
    static let legend =
        "Click a slot, a track name or a slot number to leave it out of the export. "
        + "Leaving a slot out closes the gap, so what follows it plays earlier."

    /// One pattern slot on one track. Both numbers are the device's own, 1-based.
    struct Cell: Sendable, Hashable {
        let track: Int
        let pattern: Int
    }

    /// A row or column header's state. `mixed` is the third one a checkbox needs and a Bool cannot
    /// carry: some of that row is on and some of it is off.
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

    /// Inert: no project has been read yet, so there is nothing to tick and nothing to block.
    init() {
        self.tracks = []
        self.names = [:]
        self.patterns = []
    }

    /// Sized and named from the project that was dropped, with everything ticked.
    init(_ summary: ProjectSummary) {
        self.tracks = summary.tracks.map(\.number)
        // Kept rather than trusted unique: the reader can hand over whatever the file holds, and
        // a preview must not trap on it -- the same stance ``PatternGrid/Row`` takes.
        self.names = Dictionary(
            summary.tracks.map { ($0.number, $0.name) }, uniquingKeysWith: { first, _ in first })
        self.patterns = Array(1...AppLayout.columnCount)
    }

    /// No grid behind it. Every question below answers as if nothing were selectable.
    var isInert: Bool { tracks.isEmpty || patterns.isEmpty }

    func isTicked(track: Int, pattern: Int) -> Bool {
        !unticked.contains(Cell(track: track, pattern: pattern))
    }

    /// A row's header state, read across the slots that are still in play.
    ///
    /// Excluding a whole slot switches one cell off in every row, and that must not leave every row
    /// reading as mixed: the rows and columns of a rectangle have to keep reading as whole, or a
    /// click on one of them would undo the other.
    func state(ofTrack track: Int) -> Tick {
        state(of: livePatterns.map { Cell(track: track, pattern: $0) })
    }

    /// A column's header state, read across the tracks still in play, for the same reason.
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

    /// A whole row. A header that is only partly on ticks the rest of itself rather than clearing
    /// it, so one click never takes away more than the header shows -- and ticking one leaves the
    /// slots that are off on every track alone, so bringing a track back does not undo a column.
    mutating func toggle(track: Int) {
        let ticked = state(ofTrack: track) != .on
        let reached = ticked ? livePatterns : patterns
        set(reached.map { Cell(track: track, pattern: $0) }, ticked: ticked)
    }

    /// A whole pattern slot, across every track. The mirror of ``toggle(track:)``.
    mutating func toggle(pattern: Int) {
        let ticked = state(ofPattern: pattern) != .on
        let reached = ticked ? liveTracks : tracks
        set(reached.map { Cell(track: $0, pattern: pattern) }, ticked: ticked)
    }

    /// The tracks the export is asked for -- and **empty when every one of them is ticked**, which
    /// is how both CLIs spell "all". That is what keeps the app on defaults byte-identical to today.
    ///
    /// Empty also when nothing at all is ticked, which would mean the opposite; ``blockReason``
    /// stops that selection from ever reaching a runner.
    var selectedTracks: Set<Int> { tickedTracks.count == tracks.count ? [] : tickedTracks }

    var selectedPatterns: Set<Int> { tickedPatterns.count == patterns.count ? [] : tickedPatterns }

    /// Why Convert is off, or `nil` when it is on. The single source of that answer, so the button
    /// is never dead without the window saying why.
    var blockReason: String? {
        guard !isInert else { return nil }
        guard !tickedCells.isEmpty else {
            return "Nothing is ticked. Tick at least one pattern slot to convert."
        }

        // Rectangular means the ticked set *is* the cross product of its own projections. The first
        // cell in that product which is not ticked is the one the message names.
        let rows = tickedTracks
        let columns = tickedPatterns
        for track in tracks where rows.contains(track) {
            for pattern in patterns
            where columns.contains(pattern) && !isTicked(track: track, pattern: pattern) {
                // A ticked column has to be on somewhere, and not here -- so there is another track
                // to name, and naming it is what makes the conflict a conflict rather than a rule.
                guard
                    let other = tracks.first(where: {
                        $0 != track && isTicked(track: $0, pattern: pattern)
                    })
                else { continue }
                return
                    "Pattern slot \(pattern) is off for \(name(track)) but on for \(name(other)). "
                    + "A slot has to be excluded on every track or on none."
            }
        }
        return nil
    }

    /// What the result says was left out, or `nil` when everything was converted.
    var exclusionNote: String? {
        guard !isInert, !unticked.isEmpty else { return nil }
        let rows = tickedTracks
        let columns = tickedPatterns
        let missingTracks = tracks.filter { !rows.contains($0) }
        let missingPatterns = patterns.filter { !columns.contains($0) }

        var parts: [String] = []
        if !missingTracks.isEmpty {
            parts.append(missingTracks.map(name).joined(separator: ", "))
        }
        if !missingPatterns.isEmpty {
            let slots = missingPatterns.map(String.init).joined(separator: ", ")
            parts.append("pattern slot\(missingPatterns.count == 1 ? "" : "s") \(slots)")
        }
        // A selection that is not a rectangle excludes neither a whole track nor a whole slot, so
        // there is nothing to report; ``blockReason`` is what answers for that one.
        return parts.isEmpty ? nil : "Excluded: " + parts.joined(separator: " · ")
    }

    /// The exported track name, so the reason and the note read the way the grid's own labels and
    /// the `.mid` do.
    func name(_ track: Int) -> String { names[track] ?? "Track \(track)" }

    private var tickedCells: [Cell] {
        tracks.flatMap { track in
            patterns.map { Cell(track: track, pattern: $0) }
        }.filter { !unticked.contains($0) }
    }

    private var tickedTracks: Set<Int> { Set(tickedCells.map(\.track)) }

    private var tickedPatterns: Set<Int> { Set(tickedCells.map(\.pattern)) }

    /// The tracks a column header is read across: the ones not switched off in their entirety.
    /// Nothing ticked at all switches every track off, and there the whole grid comes back into
    /// play -- otherwise a click would reach nothing and that state could never be left.
    private var liveTracks: [Int] {
        let live = tracks.filter { track in
            patterns.contains { isTicked(track: track, pattern: $0) }
        }
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
