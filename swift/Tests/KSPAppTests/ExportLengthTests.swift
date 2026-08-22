import Foundation
import KSPKit
import KSPRun
import Testing

@testable import KSPApp

/// The wording matters as much as the count: nothing renders it to a CLI to catch a drift.
@Suite struct ExportLengthTests {

    private func length(
        _ summary: ProjectSummary, repeatCount: Int = 1, isSplit: Bool = false
    ) -> ExportLength {
        ExportLength(
            summary, selection: GridSelection(summary), repeatCount: repeatCount, isSplit: isSplit)
    }

    private let threeSlots: [Int: [Int: SlotCount]] = [
        1: [1: (held: 4, enabled: 4), 2: (held: 8, enabled: 8), 3: (held: 2, enabled: 2)]
    ]

    @Test func anEmptySlotIsNeverCounted() {
        #expect(length(syntheticSummary(notes: threeSlots)).patterns == 3)
    }

    /// `arrange` lays out one slot per pattern *number*, however many tracks play it.
    @Test func aslotTwoTracksShareIsCountedOnce() {
        let summary = syntheticSummary(notes: [
            1: [1: (held: 4, enabled: 4), 2: (held: 4, enabled: 4)],
            3: [1: (held: 9, enabled: 9)],
        ])

        #expect(length(summary).patterns == 2)
    }

    @Test func aslotThatIsSilentStillTakesItsRoom() {
        #expect(length(syntheticSummary(notes: [1: [1: (held: 76, enabled: 0)]])).patterns == 1)
    }

    @Test func untickingAslotOnEveryTrackDropsTheCount() {
        let summary = syntheticSummary(notes: threeSlots)
        var selection = GridSelection(summary)
        selection.toggle(pattern: 2)

        #expect(
            ExportLength(summary, selection: selection, repeatCount: 1, isSplit: false).patterns
                == 2)
    }

    @Test func untickingAslotOnOneTrackAloneDoesNot() {
        let summary = syntheticSummary(notes: [
            1: [1: (held: 4, enabled: 4)], 2: [1: (held: 4, enabled: 4)],
        ])
        var selection = GridSelection(summary)
        selection.toggle(track: 1, pattern: 1)

        #expect(
            ExportLength(summary, selection: selection, repeatCount: 1, isSplit: false).patterns
                == 1)
    }

    @Test func oneRepeatStatesThePatternCountAndNothingElse() {
        #expect(length(syntheticSummary(notes: threeSlots)).line == "3 patterns end to end.")
    }

    @Test func asingleSlotIsSaidInTheSingular() {
        let summary = syntheticSummary(notes: [1: [1: (held: 4, enabled: 4)]])

        #expect(length(summary).line == "1 pattern end to end.")
    }

    @Test func moreThanOneStatesBothFactorsTheProductAndThatItIsExportOnly() {
        let line = length(syntheticSummary(notes: threeSlots), repeatCount: 3).line

        #expect(
            line == "3 patterns × 3 repeats — 9 patterns end to end. "
                + "Repeats exist only in the .mid.")
    }

    @Test func theMultiplierIsSaidOnlyWhenItDoesSomething() {
        let summary = syntheticSummary(notes: threeSlots)

        #expect(length(summary, repeatCount: 1).line?.contains("×") == false)
        #expect(length(summary, repeatCount: 2).line?.contains("×") == true)
    }

    @Test(arguments: 1...10)
    func theProductIsThePatternsTimesTheRepeats(count: Int) {
        let length = length(syntheticSummary(notes: threeSlots), repeatCount: count)

        #expect(length.total == 3 * count)
        #expect(length.repeatCount == count)
    }

    /// `exportSplit` groups by (track, pattern), so a split file is one pattern long.
    @Test func asplitIsMeasuredPerFile() {
        let summary = syntheticSummary(notes: threeSlots)

        #expect(length(summary, isSplit: true).line == "One pattern per file.")
        #expect(
            length(summary, repeatCount: 3, isSplit: true).line
                == "One pattern × 3 repeats per file. Repeats exist only in the .mid.")
    }

    @Test func asplitFileIsOnePatternLongHoweverManyAreTicked() {
        let length = length(syntheticSummary(notes: threeSlots), repeatCount: 4, isSplit: true)

        #expect(length.total == 4)
    }

    @Test func asplitOfNothingSaysNothingWouldBeWritten() {
        #expect(
            length(syntheticSummary(), isSplit: true).line
                == "No ticked slot holds anything, so nothing would be written.")
    }

    @Test func nothingTickedDrawsNoLine() {
        let summary = syntheticSummary(notes: threeSlots)
        var selection = GridSelection(summary)
        for pattern in 1...16 { selection.toggle(pattern: pattern) }

        #expect(
            ExportLength(summary, selection: selection, repeatCount: 4, isSplit: false).line == nil)
    }

    @Test func anEmptyProjectSaysNothingWouldBeWritten() {
        let length = length(syntheticSummary(), repeatCount: 4)

        #expect(length.patterns == 0)
        #expect(length.line == "No ticked slot holds anything, so nothing would be written.")
    }

    /// `selectedCells` is not empty here, so Convert stays enabled and this line is the warning.
    @Test func tickingOnlyEmptySlotsSaysNothingWouldBeWritten() {
        let summary = syntheticSummary(notes: threeSlots)
        var selection = GridSelection(summary)
        for pattern in 1...3 { selection.toggle(pattern: pattern) }

        let length = ExportLength(
            summary, selection: selection, repeatCount: 2, isSplit: false)

        #expect(selection.blockReason == nil)
        #expect(length.line == "No ticked slot holds anything, so nothing would be written.")
    }
}
