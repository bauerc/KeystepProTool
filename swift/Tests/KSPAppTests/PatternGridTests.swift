import Foundation
import KSPKit
import KSPRun
import Testing

@testable import KSPApp

/// The staged view's track x pattern grid (#128), decided away from SwiftUI so its rules can be
/// asserted rather than looked at.
///
/// The wording tests are regression guards: #127 wrote these strings, this issue only moved them,
/// and nothing renders them to a CLI so nothing else would catch a drift.
@Suite struct PatternGridTests {

    // MARK: - Shape

    /// All four tracks against all sixteen slots, whether or not anything was ever recorded in
    /// them -- a grid with a track or a column missing cannot show how the project lines up.
    @Test(arguments: ["project_5.KeyStepPro", "initial_project.KeyStepPro", "project_9.KeyStepPro"])
    func itDrawsEveryTrackAgainstEverySlot(_ name: String) throws {
        let grid = PatternGrid(try summarise(name))

        #expect(grid.columns == Array(1...16))
        #expect(grid.rows.count == 4)
        #expect(grid.rows.map(\.track) == [1, 2, 3, 4])
        for row in grid.rows {
            #expect(row.cells.map(\.pattern) == Array(1...16))
        }
    }

    /// An empty project still draws the full grid: four rows of dimmed slots, not nothing.
    @Test func anEmptyProjectStillDrawsAFullGrid() throws {
        let grid = PatternGrid(try summarise("user_empty_project.KeyStepPro"))

        #expect(grid.rows.count == 4)
        #expect(grid.rows.allSatisfy { $0.cells.allSatisfy(\.isEmpty) })
    }

    // MARK: - What a cell says

    /// The two states a dimmed cell could not tell apart. Now that the column header carries the
    /// pattern number, a slot holding notes with every one switched off has to print its `0`:
    /// reading it as empty would hide a pattern that is there but silent.
    @Test func anEmptySlotIsAnEmDashAndASilentOneIsAZero() {
        let grid = PatternGrid(
            syntheticSummary(notes: [1: [1: (held: 76, enabled: 0), 2: (held: 12, enabled: 8)]]))
        let cells = grid.rows[0].cells

        #expect(cells[0].label == "0")
        #expect(cells[0].isEmpty == false)
        #expect(cells[1].label == "8")
        #expect(cells[1].isEmpty == false)
        #expect(cells[2].label == "—")
        #expect(cells[2].isEmpty)
    }

    /// The count is the enabled one, which is why the grid carries a legend saying so: the two
    /// switches the device offers, not the six reasons a note might not sound. "Events" and not
    /// "notes" because a drum track's are Triggers, and one legend sits under all four rows.
    @Test func theLegendSaysWhichCountTheCellsCarry() {
        #expect(
            PatternGrid.legend == "Counts are events switched on. Hover a slot for what it holds.")
    }

    // MARK: - Wording carried over from #127

    @Test func theHeaderCarriesTempoSwingAndScene() {
        let grid = PatternGrid(
            syntheticSummary(tempoBPM: 128.5, globalSwingPercent: 62, currentScene: 3))

        #expect(grid.header == "128.5 BPM · swing 62% · scene 3")
    }

    @Test func aWholeNumberedTempoRendersWithoutADecimalPoint() {
        #expect(PatternGrid(syntheticSummary(tempoBPM: 120)).header.hasPrefix("120 BPM"))
    }

    @Test func aTrackDetailCountsItsPatternsAndItsSwitchedOnNotes() {
        let grid = PatternGrid(
            syntheticSummary(notes: [
                1: [1: (held: 20, enabled: 18), 5: (held: 30, enabled: 22)],
                2: [1: (held: 2, enabled: 1)],
            ]))

        #expect(grid.rows[0].detail == "2 patterns · 40 notes switched on")
        #expect(grid.rows[1].detail == "1 pattern · 1 note switched on")
        #expect(grid.rows[2].detail == "empty")
    }

    @Test func adrumTrackIsCountedInTriggers() {
        let grid = PatternGrid(
            syntheticSummary(drumTracks: [3], notes: [3: [1: (held: 12, enabled: 9)]]))

        #expect(grid.rows[2].detail == "1 pattern · 9 triggers switched on")
        #expect(
            grid.rows[2].cells[0].detail == "Pattern 1 — 12 triggers held, 9 switched on, 16 steps")
    }

    @Test func aslotDetailSeparatesHeldFromSwitchedOn() {
        let grid = PatternGrid(syntheticSummary(notes: [1: [4: (held: 76, enabled: 8)]]))

        #expect(
            grid.rows[0].cells[3].detail == "Pattern 4 — 76 notes held, 8 switched on, 16 steps")
        #expect(grid.rows[0].cells[0].detail == "Pattern 1 — empty")
    }

    // MARK: - Chains

    /// A run that ascends by one is one continuous rail, sized by the same constants the cells are.
    @Test func anascendingChainBecomesOneRail() {
        let grid = PatternGrid(syntheticSummary(chains: [1: [1, 2, 3]]))
        let row = grid.rows[0]

        #expect(row.cells[0].positions == [1])
        #expect(row.cells[1].positions == [2])
        #expect(row.cells[2].positions == [3])
        #expect(row.cells[3].positions.isEmpty)

        #expect(row.runs.count == 1)
        #expect(row.runs[0].x == AppLayout.labelWidth + AppLayout.labelGap)
        #expect(row.runs[0].width == 3 * AppLayout.cellWidth + 2 * AppLayout.cellSpacing)
    }

    /// A Chain is a play order, not a range, so `[3, 1, 7]` is representable: the cells are marked
    /// with where they play, and no rail is drawn.
    @Test func ascatteredChainIsMarkedButNotJoined() {
        let grid = PatternGrid(syntheticSummary(chains: [2: [3, 1, 7]]))
        let row = grid.rows[1]

        #expect(row.cells[2].positions == [1])
        #expect(row.cells[0].positions == [2])
        #expect(row.cells[6].positions == [3])
        #expect(row.runs.isEmpty)
    }

    /// A Chain may play the same Pattern twice, so a cell carries every place it sits in the run
    /// rather than one. The rail is still drawn once.
    @Test func arepeatedPatternCarriesEveryPlaceItPlays() {
        let grid = PatternGrid(syntheticSummary(chains: [1: [1, 2, 1, 3]]))
        let row = grid.rows[0]

        #expect(row.cells[0].positions == [1, 3])
        #expect(row.cells[1].positions == [2])
        #expect(row.cells[2].positions == [4])
        // Only 1 -> 2 is consecutive in both play order and grid order; the 1 -> 3 hop is not.
        #expect(row.runs.count == 1)
        #expect(row.runs[0].width == 2 * AppLayout.cellWidth + AppLayout.cellSpacing)
    }

    /// The last two slots: the rail has to stop exactly at the grid's right edge, which is the
    /// arithmetic the fit depends on.
    @Test func arailOnTheLastTwoSlotsEndsAtTheGridsEdge() throws {
        let grid = PatternGrid(syntheticSummary(chains: [1: [15, 16]]))
        let run = try #require(grid.rows[0].runs.first)

        #expect(run.x + run.width == AppLayout.gridWidth)
    }

    /// A Pattern number the grid has no column for is dropped rather than indexed: the geometry
    /// must not trap on a project the reader let through.
    @Test func achainValueOutsideTheSixteenSlotsIsIgnored() {
        let grid = PatternGrid(syntheticSummary(chains: [1: [0, 2, 17, 3]]))
        let row = grid.rows[0]

        #expect(row.cells.filter { !$0.positions.isEmpty }.map(\.pattern) == [2, 3])
        // Dropping the 17 must not join 2 to 3 across the gap it leaves.
        #expect(row.runs.isEmpty)
    }

    /// Where a rail cannot be drawn, the tooltip is what says the cell is chained at all -- and it
    /// is the only place a Pattern the Chain plays twice can say so.
    @Test func achainedSlotSaysWhereItPlays() {
        let grid = PatternGrid(
            syntheticSummary(chains: [1: [1, 2, 1]], notes: [1: [1: (held: 4, enabled: 4)]]))
        let cells = grid.rows[0].cells

        #expect(
            cells[0].detail
                == "Pattern 1 — 4 notes held, 4 switched on, 16 steps · Chain places 1 and 3")
        #expect(cells[1].detail == "Pattern 2 — empty · Chain place 2")
        #expect(cells[2].detail == "Pattern 3 — empty")
    }

    @Test func achainReadsInPlayOrderUnderItsOwnRow() {
        let grid = PatternGrid(syntheticSummary(chains: [2: [3, 1, 7]]))

        #expect(grid.rows[1].chainDetail == "Chain: 3 → 1 → 7")
        #expect(grid.rows[0].chainDetail == nil)
    }

    // MARK: - The fit

    /// The acceptance criterion as arithmetic, so a change to the window or the sidebar fails here
    /// rather than clipping the pattern axis in silence.
    @Test func thegridFitsTheStagedPaneWithoutTruncatingThePatternAxis() {
        #expect(AppLayout.gridWidth <= AppLayout.contentWidth)
        #expect(AppLayout.columnCount == 16)
    }

    /// One end-to-end pass: a real project through the shipped runner and out as a drawable grid.
    @Test func arealProjectSummarisesStraightIntoAGrid() throws {
        let grid = PatternGrid(try summarise("project_5.KeyStepPro"))

        #expect(grid.header.hasSuffix("scene 1"))
        #expect(grid.rows.contains { $0.cells.contains { !$0.isEmpty } })
        #expect(grid.rows.allSatisfy { $0.chainDetail == nil })
    }
}
