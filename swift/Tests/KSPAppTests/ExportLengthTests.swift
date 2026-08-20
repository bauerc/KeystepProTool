import Foundation
import KSPKit
import KSPRun
import Testing

@testable import KSPApp

/// The pre-flight line under the grid: how long the export runs, in the two things that set it.
///
/// Decided away from SwiftUI so the arithmetic and the wording can both be asserted. The wording
/// matters as much as the count -- nothing renders it to a CLI, so nothing else would catch a drift.
@Suite struct ExportLengthTests {

    /// Everything ticked, which is where a fresh drop starts.
    private func length(
        _ summary: ProjectSummary, repeatCount: Int = 1, isSplit: Bool = false
    ) -> ExportLength {
        ExportLength(
            summary, selection: GridSelection(summary), repeatCount: repeatCount, isSplit: isSplit)
    }

    private let threeSlots: [Int: [Int: SlotCount]] = [
        1: [1: (held: 4, enabled: 4), 2: (held: 8, enabled: 8), 3: (held: 2, enabled: 2)]
    ]

    // MARK: - What it counts

    /// A slot the grid draws as an em dash holds nothing, so `renderProject` plans nothing for it
    /// and it takes up no room on the timeline. Counting it would overstate every export.
    @Test func anEmptySlotIsNeverCounted() {
        #expect(length(syntheticSummary(notes: threeSlots)).patterns == 3)
    }

    /// The pattern axis is shared: `arrange` lays out one slot per pattern *number*, however many
    /// tracks play it, so two tracks holding slot 1 are one pattern's worth of timeline.
    @Test func aslotTwoTracksShareIsCountedOnce() {
        let summary = syntheticSummary(notes: [
            1: [1: (held: 4, enabled: 4), 2: (held: 4, enabled: 4)],
            3: [1: (held: 9, enabled: 9)],
        ])

        #expect(length(summary).patterns == 2)
    }

    /// A pattern holding notes with every one switched off still has its steps, so it still takes
    /// its room on the timeline. This is the "enabled, not audible" line the grid's legend draws.
    @Test func aslotThatIsSilentStillTakesItsRoom() {
        #expect(length(syntheticSummary(notes: [1: [1: (held: 76, enabled: 0)]])).patterns == 1)
    }

    // MARK: - What the ticks do to it

    @Test func untickingAslotOnEveryTrackDropsTheCount() {
        let summary = syntheticSummary(notes: threeSlots)
        var selection = GridSelection(summary)
        selection.toggle(pattern: 2)

        #expect(
            ExportLength(summary, selection: selection, repeatCount: 1, isSplit: false).patterns
                == 2)
    }

    /// The slot still plays on the track that kept it, so the timeline is no shorter. A count that
    /// dropped here would promise a shorter file than the export writes.
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

    // MARK: - What it says

    @Test func oneRepeatStatesThePatternCountAndNothingElse() {
        #expect(length(syntheticSummary(notes: threeSlots)).line == "3 patterns end to end.")
    }

    @Test func asingleSlotIsSaidInTheSingular() {
        let summary = syntheticSummary(notes: [1: [1: (held: 4, enabled: 4)]])

        #expect(length(summary).line == "1 pattern end to end.")
    }

    /// Both factors and the product, because the product is the thing the reader came for -- and
    /// the export-only sentence, because that is what keeps this apart from the Step Skip cycle.
    @Test func moreThanOneStatesBothFactorsTheProductAndThatItIsExportOnly() {
        let line = length(syntheticSummary(notes: threeSlots), repeatCount: 3).line

        #expect(
            line == "3 patterns × 3 repeats — 9 patterns end to end. "
                + "Repeats exist only in the .mid.")
    }

    /// At the default the multiplier is not mentioned at all: a "× 1 repeat" in every window would
    /// be noise, and raising the stepper has to visibly change the sentence.
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

    // MARK: - What splitting does to the unit

    /// `exportSplit` groups the renderings by (track, pattern) and repeats each group, so a split
    /// file is one pattern long however many slots were ticked. Saying "3 patterns end to end"
    /// here would describe a file the run never writes.
    @Test func asplitIsMeasuredPerFile() {
        let summary = syntheticSummary(notes: threeSlots)

        #expect(length(summary, isSplit: true).line == "One pattern per file.")
        #expect(
            length(summary, repeatCount: 3, isSplit: true).line
                == "One pattern × 3 repeats per file. Repeats exist only in the .mid.")
    }

    /// One pattern's worth, repeated -- not the whole ticked grid's.
    @Test func asplitFileIsOnePatternLongHoweverManyAreTicked() {
        let length = length(syntheticSummary(notes: threeSlots), repeatCount: 4, isSplit: true)

        #expect(length.total == 4)
    }

    /// An empty project has nothing to lay down whichever way the export writes it.
    @Test func asplitOfNothingSaysNothingWouldBeWritten() {
        #expect(
            length(syntheticSummary(), isSplit: true).line
                == "No ticked slot holds anything, so nothing would be written.")
    }

    // MARK: - When there is nothing to say

    /// Untick everything and Convert is blocked with its own reason; a line here as well would be
    /// a second, quieter answer to the same question.
    @Test func nothingTickedDrawsNoLine() {
        let summary = syntheticSummary(notes: threeSlots)
        var selection = GridSelection(summary)
        for pattern in 1...16 { selection.toggle(pattern: pattern) }

        #expect(
            ExportLength(summary, selection: selection, repeatCount: 4, isSplit: false).line == nil)
    }

    /// Nothing is unticked, so Convert is not blocked and nothing else would say the run writes no
    /// notes. Going quiet here would leave an empty project looking ready to export.
    @Test func anEmptyProjectSaysNothingWouldBeWritten() {
        let length = length(syntheticSummary(), repeatCount: 4)

        #expect(length.patterns == 0)
        #expect(length.line == "No ticked slot holds anything, so nothing would be written.")
    }

    /// Ticks on nothing but empty slots: `selectedCells` is not empty, so Convert stays enabled and
    /// this line is the only warning the user gets before pressing it.
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
