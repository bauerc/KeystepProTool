import Foundation
import KSPKit
import KSPRun

/// Every dimension the staged view is laid out from -- the window's as well as the grid's, because
/// the fit is a subtraction between them and the two must not drift apart.
///
/// The pane the grid draws in scrolls vertically only, so a grid wider than ``contentWidth`` is
/// silently clipped rather than scrolled. A test holds ``gridWidth`` under it.
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
///
/// Every decision the grid makes is taken here rather than in `DropView`, so it can be asserted
/// instead of looked at -- which matters most for the Chain rails, since no sample project in the
/// repository has a Chain to eyeball.
struct PatternGrid: Equatable {
    /// Says which count the cells carry, because "enabled" and "held" can differ by a lot and the
    /// grid has room for only one of them. "Events" because the rows below it are a mix: a
    /// sequencer track counts Notes and a drum track counts Triggers, and one legend covers both.
    static let legend = "Counts are events switched on. Hover a slot for what it holds."

    /// One pattern slot on one track.
    struct Cell: Equatable {
        /// 1-16.
        let pattern: Int
        /// What the cell prints: the enabled count, or an em dash when the slot holds nothing.
        let label: String
        let isEmpty: Bool
        /// Where this Pattern plays in its track's Chain, 1-based, in play order. More than one
        /// place when the Chain plays it twice; empty when it is in no Chain.
        let positions: [Int]
        let detail: String

        init(_ pattern: PatternSummary, mode: TrackMode, positions: [Int]) {
            self.pattern = pattern.number
            self.label = pattern.isEmpty ? "—" : "\(pattern.enabledNoteCount)"
            self.isEmpty = pattern.isEmpty
            self.positions = positions
            self.detail = Self.detail(pattern, mode: mode, positions: positions)
        }

        /// Held and switched on side by side rather than as a fraction: a Pattern can hold the other
        /// set's notes too, and what closed the gap is the diagnostics' to say, not a tooltip's.
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
            // Where a rail cannot be drawn -- a Chain that jumps -- this is what says the cell is
            // in one, and a Pattern the Chain plays twice says so here rather than nowhere.
            let places = positions.map(String.init).joined(separator: " and ")
            return detail + " · Chain place\(positions.count == 1 ? "" : "s") \(places)"
        }
    }

    /// One continuous Chain rail, in points from its row's leading edge.
    struct ChainRun: Equatable {
        let x: CGFloat
        let width: CGFloat
    }

    /// One track's row: its sixteen cells, and the rails drawn behind them.
    struct Row: Equatable {
        /// 1-4.
        let track: Int
        let name: String
        /// The row label's tooltip. A sixteen-column grid leaves no room to show it outright.
        let detail: String
        /// The Chain in play order, or nil when the track is in none. Drawn under this row rather
        /// than collected with the others, so it never has to be matched back to a track.
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

        /// Says "switched on" because that is what the number is -- the same count the cells carry,
        /// not everything the track holds.
        private static func detail(_ track: TrackSummary) -> String {
            guard !track.isEmpty else { return "empty" }
            let held = track.patterns.count(where: { !$0.isEmpty })
            let notes = track.patterns.reduce(0) { $0 + $1.enabledNoteCount }
            let noun = track.mode == .drum ? "trigger" : "note"
            return "\(held) pattern\(held == 1 ? "" : "s") · \(notes) "
                + "\(noun)\(notes == 1 ? "" : "s") switched on"
        }

        /// Every place each Pattern plays. A Pattern number the grid has no column for is dropped
        /// rather than indexed: the reader can hand one over and the geometry must not trap on it.
        private static func places(in chain: [Int]) -> [Int: [Int]] {
            var places: [Int: [Int]] = [:]
            for (index, pattern) in chain.enumerated() where drawable(pattern) {
                places[pattern, default: []].append(index + 1)
            }
            return places
        }

        /// The rails. A Chain is a play order, not a range, so two cells are joined only where the
        /// Chain plays one straight after the other *and* they are neighbouring columns; anything
        /// else stays marked but unjoined rather than claiming an adjacency the device lacks.
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
