import Foundation
import KSPKit
import KSPRun

/// The preview grid: four tracks down, sixteen pattern slots across.
struct PatternGrid: Equatable {
    struct Cell: Equatable {
        /// 1-16.
        let pattern: Int
        let label: String
        let isEmpty: Bool
        /// Everything the slot holds, which the fill's intensity is of. Not ``label``'s figure:
        /// that is what is switched on, and a full pattern of switched-off steps is still full.
        let noteCount: Int
        /// The live set's declared step count, which the length rule is a fraction of.
        let stepCount: Int
        /// Where this Pattern plays in its Chain, 1-based, in play order; empty when in none.
        let positions: [Int]
        let detail: String
        /// ``detail`` without the slot's name, which is what the cell is labelled with.
        let spoken: String

        init(_ pattern: PatternSummary, mode: TrackMode, positions: [Int]) {
            self.pattern = pattern.number
            self.label = pattern.isEmpty ? "—" : "\(pattern.enabledNoteCount)"
            self.isEmpty = pattern.isEmpty
            self.noteCount = pattern.noteCount
            self.stepCount = pattern.stepCount
            self.positions = positions
            let body = Self.body(pattern, mode: mode, positions: positions)
            self.detail = "Pattern \(pattern.number) — \(body)"
            self.spoken = aloud(body)
        }

        private static func body(
            _ pattern: PatternSummary, mode: TrackMode, positions: [Int]
        ) -> String {
            var body = "empty"
            if !pattern.isEmpty {
                let noun = mode == .drum ? "triggers" : "notes"
                body =
                    "\(pattern.noteCount) \(noun) held, "
                    + "\(pattern.enabledNoteCount) switched on, \(pattern.stepCount) steps"
            }
            guard !positions.isEmpty else { return body }
            // Where a rail cannot be drawn -- a Chain that jumps -- this says the cell is in one.
            let places = positions.map(String.init).joined(separator: " and ")
            return body + " · Chain place\(positions.count == 1 ? "" : "s") \(places)"
        }
    }

    struct Row: Equatable {
        /// 1-4.
        let track: Int
        /// What the head prints, which is ``TrackSummary/name`` without the mode the badge carries.
        let name: String
        /// The well: two digits, or `--` where the track is on no Pattern.
        let readout: String
        let isDrum: Bool
        /// The row label's tooltip.
        let detail: String
        /// The Chain in play order, or nil when the track is in none.
        let chainDetail: String?
        /// The badge, the well, the tooltip and the Chain, said after the name as one line.
        let spoken: String
        let cells: [Cell]
        let runs: [AppLayout.Rail]

        init(_ track: TrackSummary) {
            let chain = track.chain
            let places = Self.places(in: chain)
            let playing = chain.first ?? track.patterns.first { !$0.isEmpty }?.number
            self.track = track.number
            self.name = "Track \(track.number)"
            self.readout = patternReadout(playing)
            self.isDrum = track.mode == .drum
            self.detail = "\(track.name) · " + Self.detail(track)
            self.chainDetail =
                chain.isEmpty ? nil : "Chain: " + chain.map(String.init).joined(separator: " → ")
            self.spoken = [
                track.mode == .drum ? "drum" : nil, playing.map { "on pattern \($0)" },
                aloud(Self.detail(track)),
                chain.isEmpty ? nil : "chain " + chain.map(String.init).joined(separator: " then "),
            ].compactMap { $0 }.joined(separator: ", ")
            self.cells = track.patterns.map {
                Cell($0, mode: track.mode, positions: places[$0.number] ?? [])
            }
            self.runs = Self.runs(in: chain)
        }

        private static func detail(_ track: TrackSummary) -> String {
            guard !track.isEmpty else { return "empty" }
            let held = track.patterns.count(where: { !$0.isEmpty })
            let notes = track.patterns.reduce(0) { $0 + $1.enabledNoteCount }
            let noun = track.mode == .drum ? "trigger" : "note"
            return "\(held) pattern\(held == 1 ? "" : "s") · \(notes) "
                + "\(noun)\(notes == 1 ? "" : "s") switched on"
        }

        /// A Pattern number the grid has no column for is dropped rather than indexed.
        private static func places(in chain: [Int]) -> [Int: [Int]] {
            var places: [Int: [Int]] = [:]
            for (index, pattern) in chain.enumerated() where drawable(pattern) {
                places[pattern, default: []].append(index + 1)
            }
            return places
        }

        /// A Chain is a play order, not a range: two cells join only where it plays one straight
        /// after the other *and* they are neighbouring columns.
        private static func runs(in chain: [Int]) -> [AppLayout.Rail] {
            var links: Set<Int> = []
            for (from, to) in zip(chain, chain.dropFirst())
            where drawable(from) && drawable(to) && to == from + 1 {
                links.insert(from)
            }
            return AppLayout.rails(joining: links)
        }

        private static func drawable(_ pattern: Int) -> Bool {
            (1...AppLayout.columnCount).contains(pattern)
        }
    }

    let header: String
    let columns: [Int]
    let rows: [Row]

    init(_ summary: ProjectSummary) {
        self.header =
            "\(Arithmetic.general(summary.tempoBPM)) BPM · swing "
            + "\(summary.globalSwingPercent)% · scene \(summary.currentScene)"
        self.columns = Array(1...AppLayout.columnCount)
        self.rows = summary.tracks.map(Row.init)
    }
}

/// The pattern slots the grid has ticked that hold anything. What they come to end to end is the
/// arrange lanes' header to say, so this speaks only when it is nothing.
struct ExportLength: Equatable {
    /// Ticked slots that hold something, counted once however many tracks play them.
    let patterns: Int
    /// Convert already refuses an empty selection in its own words.
    let isBlocked: Bool

    /// Ticks on nothing but empty slots leave Convert enabled, so only this says so.
    var warning: String? {
        guard !isBlocked, patterns == 0 else { return nil }
        return "No ticked slot holds anything, so nothing would be written."
    }

    init(_ summary: ProjectSummary, selection: GridSelection) {
        self.patterns = (1...AppLayout.columnCount).count { pattern in
            summary.tracks.contains { track in
                selection.isTicked(track: track.number, pattern: pattern)
                    && track.patterns.contains { $0.number == pattern && !$0.isEmpty }
            }
        }
        self.isBlocked = selection.blockReason != nil
    }
}
