import Foundation
import KSPKit
import KSPRun

/// Every dimension the staged view is laid out from. The window resizes freely above a floor and
/// its pane scrolls vertically only, so a row wider than ``minimumContentWidth`` is clipped at the
/// smallest window; a test holds each row under it.
enum AppLayout {
    /// The window's floor, not its size: it resizes above this, and the width goes to a track name.
    static let minimumWindowWidth: CGFloat = 1020
    static let minimumWindowHeight: CGFloat = 440
    /// What a first launch opens at; afterwards the window restores the size it was left at.
    static let defaultWindowWidth: CGFloat = 1120
    static let defaultWindowHeight: CGFloat = 600
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

    /// The source-track list a dropped MIDI file previews as, column by column.
    static let trackTickWidth: CGFloat = 18
    static let trackNumberWidth: CGFloat = 22
    /// The one column that stretches with the window; this is all it keeps at the floor.
    static let trackNameMinWidth: CGFloat = 150
    static let trackBadgeWidth: CGFloat = 78
    static let trackChannelsWidth: CGFloat = 88
    static let trackCountsWidth: CGFloat = 150
    /// "Automatic — Tracks 2, 3" is the longest a destination reads.
    static let trackDestinationWidth: CGFloat = 170
    static let trackColumnGap: CGFloat = 8

    /// The limit block's two aligned columns. "Patterns per track" is the longest name, and
    /// "192 / 192" the widest figure.
    static let limitNameWidth: CGFloat = 128
    static let limitFigureWidth: CGFloat = 62

    /// The staged pane at ``minimumWindowWidth`` -- the narrowest it ever gets, and so the only
    /// width at which a row being clipped cannot be resized away.
    static var minimumContentWidth: CGFloat {
        minimumWindowWidth - sidebarWidth - dividerWidth - 2 * mainPadding - scrollerAllowance
    }

    /// Where the pattern axis starts, measured from a row's leading edge.
    static var gridOrigin: CGFloat { labelWidth + labelGap }

    static var gridWidth: CGFloat {
        gridOrigin + CGFloat(columnCount) * cellWidth + CGFloat(columnCount - 1) * cellSpacing
    }

    /// Every column a track row draws, in order, at the width it never goes below. A column drawn
    /// but left out of this overflows the pane in silence, which is how the destination picker did.
    static let trackColumnWidths: [CGFloat] = [
        trackTickWidth, trackNumberWidth, trackNameMinWidth, trackBadgeWidth, trackChannelsWidth,
        trackCountsWidth, trackDestinationWidth,
    ]

    static var trackRowWidth: CGFloat {
        trackColumnWidths.reduce(0, +) + CGFloat(trackColumnWidths.count - 1) * trackColumnGap
    }

    /// The leading edge of a column, 0-based, in its row's own coordinates.
    static func x(ofColumn index: Int) -> CGFloat {
        gridOrigin + CGFloat(index) * (cellWidth + cellSpacing)
    }

    /// One continuous rail under a row, in points from its leading edge.
    struct Rail: Equatable {
        let x: CGFloat
        let width: CGFloat
    }

    /// A rail spanning columns `from` through `to`, both 1-based.
    static func rail(from: Int, to: Int) -> Rail {
        let span = CGFloat(to - from + 1)
        return Rail(
            x: x(ofColumn: from - 1), width: span * cellWidth + (span - 1) * cellSpacing)
    }

    /// The rails over runs of joined columns, where `links` holds the column each join starts at.
    /// Shared so the export grid's Chain and the import grid's split cannot be drawn differently.
    static func rails(joining links: Set<Int>) -> [Rail] {
        var rails: [Rail] = []
        var column = 1
        while column <= columnCount {
            guard links.contains(column) else {
                column += 1
                continue
            }
            var last = column
            while links.contains(last) { last += 1 }
            rails.append(rail(from: column, to: last))
            column = last + 1
        }
        return rails
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

    struct Row: Equatable {
        /// 1-4.
        let track: Int
        let name: String
        /// The row label's tooltip.
        let detail: String
        /// The Chain in play order, or nil when the track is in none.
        let chainDetail: String?
        let cells: [Cell]
        let runs: [AppLayout.Rail]

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
