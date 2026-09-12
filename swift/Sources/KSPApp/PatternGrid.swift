import Foundation
import KSPKit
import KSPRun

struct PatternGrid: Equatable {
    struct Cell: Equatable {
        /// 1-16.
        let pattern: Int
        let label: String
        let isEmpty: Bool
        let noteCount: Int
        let stepCount: Int
        let positions: [Int]
        let detail: String
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
            let places = positions.map(String.init).joined(separator: " and ")
            return body + " · Chain place\(positions.count == 1 ? "" : "s") \(places)"
        }
    }

    struct Row: Equatable {
        /// 1-4.
        let track: Int
        let name: String
        let readout: String
        let isDrum: Bool
        let detail: String
        let chainDetail: String?
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

        private static func places(in chain: [Int]) -> [Int: [Int]] {
            var places: [Int: [Int]] = [:]
            for (index, pattern) in chain.enumerated() where drawable(pattern) {
                places[pattern, default: []].append(index + 1)
            }
            return places
        }

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

struct ExportLength: Equatable {
    let patterns: Int
    let isBlocked: Bool

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
