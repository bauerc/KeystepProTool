import Foundation
import KSPKit
import KSPRun
import Testing

@testable import KSPApp

/// The wording matters as much as the count: nothing renders it to a CLI to catch a drift.
@Suite struct ExportLengthTests {

    private func length(_ summary: ProjectSummary) -> ExportLength {
        ExportLength(summary, selection: GridSelection(summary))
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

        #expect(ExportLength(summary, selection: selection).patterns == 2)
    }

    @Test func untickingAslotOnOneTrackAloneDoesNot() {
        let summary = syntheticSummary(notes: [
            1: [1: (held: 4, enabled: 4)], 2: [1: (held: 4, enabled: 4)],
        ])
        var selection = GridSelection(summary)
        selection.toggle(track: 1, pattern: 1)

        #expect(ExportLength(summary, selection: selection).patterns == 1)
    }

    /// The length is the arrange lanes' header to say; a second line saying it again is noise.
    @Test func aselectionThatHoldsSomethingSaysNothing() {
        #expect(length(syntheticSummary(notes: threeSlots)).warning == nil)
    }

    @Test func nothingTickedDrawsNoWarning() {
        let summary = syntheticSummary(notes: threeSlots)
        var selection = GridSelection(summary)
        for pattern in 1...16 { selection.toggle(pattern: pattern) }

        #expect(ExportLength(summary, selection: selection).warning == nil)
    }

    @Test func anEmptyProjectSaysNothingWouldBeWritten() {
        let length = length(syntheticSummary())

        #expect(length.patterns == 0)
        #expect(length.warning == "No ticked slot holds anything, so nothing would be written.")
    }

    /// `selectedCells` is not empty here, so Convert stays enabled and this line is the warning.
    @Test func tickingOnlyEmptySlotsSaysNothingWouldBeWritten() {
        let summary = syntheticSummary(notes: threeSlots)
        var selection = GridSelection(summary)
        for pattern in 1...3 { selection.toggle(pattern: pattern) }

        let length = ExportLength(summary, selection: selection)

        #expect(selection.blockReason == nil)
        #expect(length.warning == "No ticked slot holds anything, so nothing would be written.")
    }
}
