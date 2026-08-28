import Foundation
import KSPKit
import KSPRun
import Testing

@testable import KSPApp

private func segmented(
    _ deviceTrack: Int, source: Int? = nil, patterns: [(pattern: Int, steps: Int)] = [],
    notes: Int = 16, isDrum: Bool = false, droppedPatterns: Int = 0
) -> SegmentedTrack {
    var step = 1
    var segments: [Segment] = []
    for entry in patterns {
        segments.append(
            Segment(pattern: entry.pattern, stepCount: entry.steps, firstStep: step))
        step += entry.steps
    }
    return SegmentedTrack(
        deviceTrack: deviceTrack, sourceTrack: source, isDrum: isDrum, noteCount: notes,
        segments: segments, droppedPatterns: droppedPatterns)
}

@Suite struct SegmentationGridTests {
    /// The device has four tracks whatever the import fills, so the grid draws four.
    @Test func itdrawsEveryDeviceTrackWhateverThePlanFilled() {
        let grid = SegmentationGrid(
            SegmentationSummary(tracks: [segmented(1, source: 3, patterns: [(1, 64)])]))

        #expect(grid.rows.count == Constants.trackItemIDs.count)
        #expect(grid.rows.map(\.track) == [1, 2, 3, 4])
        #expect(grid.columns == Array(1...AppLayout.columnCount))
        #expect(grid.rows.allSatisfy { $0.cells.count == AppLayout.columnCount })
    }

    @Test func afilledSlotCountsItsStepsAndAnEmptyOneSaysNothing() {
        let grid = SegmentationGrid(
            SegmentationSummary(tracks: [segmented(1, source: 3, patterns: [(1, 48)])]))

        let row = grid.rows[0]
        #expect(row.cells[0].label == "48")
        #expect(!row.cells[0].isEmpty)
        #expect(row.cells[1].label == "—")
        #expect(row.cells[1].isEmpty)
    }

    @Test func atrackTheImportWillNotFillReadsEmpty() {
        let grid = SegmentationGrid(
            SegmentationSummary(tracks: [segmented(1, source: 3, patterns: [(1, 64)])]))

        let row = grid.rows[1]
        #expect(row.isEmpty)
        #expect(row.cells.allSatisfy { $0.isEmpty })
        #expect(row.detail == "empty")
    }

    /// The split made visible: two patterns of one run join into one rail.
    @Test func asplitRunIsRailedAcrossThePatternsItTakes() {
        let grid = SegmentationGrid(
            SegmentationSummary(tracks: [segmented(1, source: 3, patterns: [(1, 64), (2, 32)])]))

        let row = grid.rows[0]
        #expect(row.runs.count == 1)
        #expect(row.runs[0].x == AppLayout.x(ofColumn: 0))
        #expect(row.runs[0].width == 2 * AppLayout.cellWidth + AppLayout.cellSpacing)
    }

    @Test func atrackInOnePatternHasNoRail() {
        let grid = SegmentationGrid(
            SegmentationSummary(tracks: [segmented(1, source: 3, patterns: [(1, 64)])]))

        #expect(grid.rows[0].runs.isEmpty)
    }

    /// A rail is drawn between neighbouring columns only, as the export grid's chain rail is.
    @Test func patternsThatDoNotNeighbourAreNotRailedTogether() {
        let grid = SegmentationGrid(
            SegmentationSummary(tracks: [segmented(1, source: 3, patterns: [(1, 64), (3, 64)])]))

        #expect(grid.rows[0].runs.isEmpty)
    }

    /// The acceptance criterion: shown as such rather than omitted.
    @Test func asourceThatWillNotFitIsNamedInItsOwnRight() {
        let grid = SegmentationGrid(
            SegmentationSummary(
                tracks: (1...4).map { segmented($0, source: $0, patterns: [(1, 16)]) },
                unplaced: [
                    UnplacedSource(sourceTrack: 5, noteCount: 12),
                    UnplacedSource(sourceTrack: 6, noteCount: 3),
                ]))

        #expect(grid.warnings.count == 2)
        #expect(grid.warnings[0].contains("Source track 5"))
        #expect(grid.warnings[0].contains("will not fit"))
        #expect(grid.warnings[1].contains("Source track 6"))
    }

    @Test func adroppedTailIsWarnedAboutRatherThanLeftToBeNoticed() {
        let grid = SegmentationGrid(
            SegmentationSummary(
                tracks: [segmented(1, source: 3, patterns: [(1, 64)], droppedPatterns: 2)]))

        #expect(grid.warnings.count == 1)
        #expect(grid.warnings[0].contains("Track 1"))
        #expect(grid.warnings[0].contains("2"))
    }

    @Test func anemptyPlanWarnsAboutNothing() {
        let grid = SegmentationGrid(
            SegmentationSummary(tracks: [segmented(1, source: 3, patterns: [(1, 16)])]))

        #expect(grid.warnings.isEmpty)
    }

    @Test func arowSaysWhereItsNotesCameFromAndWhatTheyFill() {
        let grid = SegmentationGrid(
            SegmentationSummary(
                tracks: [segmented(1, source: 3, patterns: [(1, 64), (2, 32)], notes: 40)]))

        let detail = grid.rows[0].detail
        #expect(detail.contains("Source track 3"))
        #expect(detail.contains("40 notes"))
        #expect(detail.contains("patterns 1-2"))
    }

    @Test func thedrumTrackSaysSo() {
        let grid = SegmentationGrid(
            SegmentationSummary(
                tracks: [segmented(1, source: 2, patterns: [(1, 16)], isDrum: true)]))

        #expect(grid.rows[0].detail.contains("drum"))
    }

    @Test func aslotSaysWhatItWillHold() {
        let grid = SegmentationGrid(
            SegmentationSummary(tracks: [segmented(1, source: 3, patterns: [(1, 64), (2, 32)])]))

        #expect(grid.rows[0].cells[1].detail.contains("Pattern 2"))
        #expect(grid.rows[0].cells[1].detail.contains("32 steps"))
        // Where the run resumes, which is the whole point of showing the split.
        #expect(grid.rows[0].cells[1].detail.contains("65"))
        #expect(grid.rows[0].cells[2].detail == "Pattern 3 — empty")
    }

    @Test func theheaderCountsWhatWouldBeLaidDown() {
        let grid = SegmentationGrid(
            SegmentationSummary(tracks: [
                segmented(1, source: 3, patterns: [(1, 64), (2, 32)]),
                segmented(2, source: 4, patterns: [(1, 16)]),
            ]))

        #expect(grid.header.contains("2 tracks"))
        #expect(grid.header.contains("3 patterns"))
    }

    @Test func thegridFitsTheStagedPaneWithoutTruncatingARow() {
        #expect(AppLayout.gridWidth <= AppLayout.contentWidth)
    }
}
