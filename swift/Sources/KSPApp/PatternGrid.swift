import Foundation
import KSPKit
import KSPRun

/// Every dimension the staged view is laid out from. Its pane scrolls vertically only, so a grid
/// wider than ``contentWidth`` is silently clipped; a test holds ``gridWidth`` under it.
enum AppLayout {
    static let windowWidth: CGFloat = 860
    static let windowHeight: CGFloat = 440
    static let sidebarWidth: CGFloat = 220
    static let dividerWidth: CGFloat = 1
    static let mainPadding: CGFloat = 24
    /// "Show scroll bars: Always" gives the staged view's `ScrollView` a scroller that takes width.
    static let scrollerAllowance: CGFloat = 15

    static let columnCount = 16
    static let labelWidth: CGFloat = 96
    static let labelGap: CGFloat = 8
    static let cellWidth: CGFloat = 26
    static let cellSpacing: CGFloat = 3
    static let cellHeight: CGFloat = 17

    static var contentWidth: CGFloat {
        windowWidth - sidebarWidth - dividerWidth - 2 * mainPadding - scrollerAllowance
    }

    /// Where the pattern axis starts, measured from a row's leading edge.
    static var gridOrigin: CGFloat { labelWidth + labelGap }

    static var gridWidth: CGFloat {
        gridOrigin + CGFloat(columnCount) * cellWidth + CGFloat(columnCount - 1) * cellSpacing
    }

    /// The leading edge of a column, 0-based, in its row's own coordinates.
    static func x(ofColumn index: Int) -> CGFloat {
        gridOrigin + CGFloat(index) * (cellWidth + cellSpacing)
    }
}

/// The preview grid: four tracks down, sixteen pattern slots across.
struct PatternGrid: Equatable {
    static let legend = "Counts are events switched on. Hover a slot for what it holds."

    struct Cell: Equatable {
        /// 1-16.
        let pattern: Int
        let label: String
        let isEmpty: Bool
        /// Where this Pattern plays in its Chain, 1-based, in play order; empty when in none.
        let positions: [Int]
        let detail: String

        init(_ pattern: PatternSummary, mode: TrackMode, positions: [Int]) {
            self.pattern = pattern.number
            self.label = pattern.isEmpty ? "—" : "\(pattern.enabledNoteCount)"
            self.isEmpty = pattern.isEmpty
            self.positions = positions
            self.detail = Self.detail(pattern, mode: mode, positions: positions)
        }

        private static func detail(
            _ pattern: PatternSummary, mode: TrackMode, positions: [Int]
        ) -> String {
            var detail = "Pattern \(pattern.number) — empty"
            if !pattern.isEmpty {
                let noun = mode == .drum ? "triggers" : "notes"
                detail =
                    "Pattern \(pattern.number) — \(pattern.noteCount) \(noun) held, "
                    + "\(pattern.enabledNoteCount) switched on, \(pattern.stepCount) steps"
            }
            guard !positions.isEmpty else { return detail }
            // Where a rail cannot be drawn -- a Chain that jumps -- this says the cell is in one.
            let places = positions.map(String.init).joined(separator: " and ")
            return detail + " · Chain place\(positions.count == 1 ? "" : "s") \(places)"
        }
    }

    /// One continuous Chain rail, in points from its row's leading edge.
    struct ChainRun: Equatable {
        let x: CGFloat
        let width: CGFloat
    }

    struct Row: Equatable {
        /// 1-4.
        let track: Int
        let name: String
        /// The row label's tooltip.
        let detail: String
        /// The Chain in play order, or nil when the track is in none.
        let chainDetail: String?
        let cells: [Cell]
        let runs: [ChainRun]

        init(_ track: TrackSummary) {
            let chain = track.chain
            let places = Self.places(in: chain)
            self.track = track.number
            self.name = track.name
            self.detail = Self.detail(track)
            self.chainDetail =
                chain.isEmpty ? nil : "Chain: " + chain.map(String.init).joined(separator: " → ")
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
        private static func runs(in chain: [Int]) -> [ChainRun] {
            var links: Set<Int> = []
            for (from, to) in zip(chain, chain.dropFirst())
            where drawable(from) && drawable(to) && to == from + 1 {
                links.insert(from)
            }

            var runs: [ChainRun] = []
            var pattern = 1
            while pattern <= AppLayout.columnCount {
                guard links.contains(pattern) else {
                    pattern += 1
                    continue
                }
                var last = pattern
                while links.contains(last) { last += 1 }
                let span = CGFloat(last - pattern + 1)
                runs.append(
                    ChainRun(
                        x: AppLayout.x(ofColumn: pattern - 1),
                        width: span * AppLayout.cellWidth
                            + (span - 1) * AppLayout.cellSpacing))
                pattern = last + 1
            }
            return runs
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

/// How long the export runs: the pattern slots the grid has ticked, and the repeat count.
struct ExportLength: Equatable {
    /// Ticked slots that hold something, counted once however many tracks play them.
    let patterns: Int
    let repeatCount: Int
    /// Splitting measures the length per file: every file is one pattern long.
    let isSplit: Bool
    /// Convert already refuses an empty selection in its own words.
    let isBlocked: Bool

    /// What comes out end to end -- of the one file, or of each file when the export splits.
    var total: Int { (isSplit ? 1 : patterns) * repeatCount }

    /// `nil` only when Convert is already blocked with its own reason.
    var line: String? {
        if isBlocked { return nil }
        // Ticks on nothing but empty slots leave Convert enabled, so only this says so.
        guard patterns > 0 else {
            return "No ticked slot holds anything, so nothing would be written."
        }
        // No count of files: a split drops any that came out empty, so the number is not known.
        if isSplit {
            guard repeatCount > 1 else { return "One pattern per file." }
            return "One pattern × \(repeatCount) repeats per file. "
                + "Repeats exist only in the .mid."
        }
        let counted = "\(patterns) pattern\(patterns == 1 ? "" : "s")"
        guard repeatCount > 1 else { return "\(counted) end to end." }
        return "\(counted) × \(repeatCount) repeats — \(total) patterns end to end. "
            + "Repeats exist only in the .mid."
    }

    init(_ summary: ProjectSummary, selection: GridSelection, repeatCount: Int, isSplit: Bool) {
        self.patterns = (1...AppLayout.columnCount).count { pattern in
            summary.tracks.contains { track in
                selection.isTicked(track: track.number, pattern: pattern)
                    && track.patterns.contains { $0.number == pattern && !$0.isEmpty }
            }
        }
        self.repeatCount = repeatCount
        self.isSplit = isSplit
        self.isBlocked = selection.blockReason != nil
    }
}
