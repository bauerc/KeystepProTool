import Foundation
import KSPRun
import Testing

@testable import KSPApp

/// The tick rule: what the export runs over, and why Convert is sometimes off.
@Suite struct GridSelectionTests {
    private func fullyTicked() -> GridSelection { GridSelection(syntheticSummary()) }

    private let everySlot = Set(1...16)

    /// Everything ticked asks for nothing, which is how the runner spells "all".
    @Test func everythingTickedSelectsEverythingByAskingForNothing() {
        let selection = fullyTicked()

        #expect(selection.selectedCells.isEmpty)
        #expect(selection.blockReason == nil)
        #expect(selection.exclusionNote == nil)
        #expect(selection.isTicked(track: 1, pattern: 1))
        #expect(selection.isTicked(track: 4, pattern: 16))
    }

    /// No project read yet: nothing to tick, nothing to complain about.
    @Test func afreshSelectionWithoutAProjectBlocksNothing() {
        let selection = GridSelection()

        #expect(selection.selectedCells.isEmpty)
        #expect(selection.blockReason == nil)
        #expect(selection.exclusionNote == nil)
    }

    @Test func untickingATrackDropsItAndKeepsTheRest() {
        var selection = fullyTicked()

        selection.toggle(track: 3)

        #expect(selection.selectedCells == [1: everySlot, 2: everySlot, 4: everySlot])
        #expect(selection.blockReason == nil)
        #expect(selection.exclusionNote == "Excluded: Track 3")
        #expect(!selection.isTicked(track: 3, pattern: 1))
        #expect(selection.isTicked(track: 2, pattern: 1))
    }

    @Test func untickingApatternSlotDropsItFromEveryTrack() {
        var selection = fullyTicked()

        selection.toggle(pattern: 5)

        let kept = everySlot.subtracting([5])
        #expect(selection.selectedCells == [1: kept, 2: kept, 3: kept, 4: kept])
        #expect(selection.blockReason == nil)
        #expect(selection.exclusionNote == "Excluded: pattern slot 5")
    }

    /// The point of the feature: one cell on one track, and the export follows it.
    @Test func untickingOneCellLeavesThatSlotOnThatTrackAlone() {
        var selection = fullyTicked()

        selection.toggle(track: 1, pattern: 3)

        #expect(
            selection.selectedCells
                == [1: everySlot.subtracting([3]), 2: everySlot, 3: everySlot, 4: everySlot])
        #expect(selection.blockReason == nil)
        #expect(selection.exclusionNote == "Excluded: Track 1 slot 3")
    }

    /// Cells chosen freely across tracks: each track keeps its own slots.
    @Test func cellsAcrossSeveralTracksAreEachKept() {
        var selection = fullyTicked()

        selection.toggle(track: 1, pattern: 3)
        selection.toggle(track: 2, pattern: 7)
        selection.toggle(track: 2, pattern: 9)

        #expect(
            selection.selectedCells
                == [
                    1: everySlot.subtracting([3]), 2: everySlot.subtracting([7, 9]),
                    3: everySlot, 4: everySlot,
                ])
        #expect(selection.blockReason == nil)
        #expect(selection.exclusionNote == "Excluded: Track 1 slot 3 · Track 2 slots 7, 9")
    }

    /// A track with every slot unticked is a track left out, however it was clicked off.
    @Test func untickingEverySlotOnAtrackDropsTheTrack() {
        var selection = fullyTicked()

        for pattern in 1...16 { selection.toggle(track: 2, pattern: pattern) }

        #expect(selection.selectedCells[2] == nil)
        #expect(selection.exclusionNote == "Excluded: Track 2")
    }

    @Test func untickingArowAndAColumnLeavesBoth() {
        var selection = fullyTicked()

        selection.toggle(track: 3)
        selection.toggle(pattern: 5)
        selection.toggle(pattern: 6)

        let kept = everySlot.subtracting([5, 6])
        #expect(selection.selectedCells == [1: kept, 2: kept, 4: kept])
        #expect(selection.exclusionNote == "Excluded: Track 3 · pattern slots 5, 6")
    }

    @Test func untickingEverythingSaysSoRatherThanConvertingNothing() {
        var selection = fullyTicked()

        for track in 1...4 { selection.toggle(track: track) }

        #expect(
            selection.blockReason == "Nothing is ticked. Tick at least one pattern slot to convert."
        )
        #expect(selection.selectedCells.isEmpty)
    }

    /// Re-ticking lands back on the default exactly, or the app stops matching the CLI on defaults.
    @Test func retickingReturnsToTheDefault() {
        var selection = fullyTicked()
        let fresh = selection

        selection.toggle(track: 2)
        selection.toggle(pattern: 7)
        selection.toggle(track: 2, pattern: 7)
        selection.toggle(track: 2, pattern: 7)
        selection.toggle(pattern: 7)
        selection.toggle(track: 2)

        #expect(selection == fresh)
        #expect(selection.selectedCells.isEmpty)
    }

    /// A slot off everywhere must not leave every row reading as half-ticked.
    @Test func awholeRowAndColumnStillReadAsWhole() {
        var selection = fullyTicked()

        selection.toggle(track: 3)
        selection.toggle(pattern: 5)

        #expect(selection.state(ofTrack: 1) == .on)
        #expect(selection.state(ofTrack: 3) == .off)
        #expect(selection.state(ofPattern: 5) == .off)
        #expect(selection.state(ofPattern: 6) == .on)
    }

    /// Bringing a track back leaves the slot that is off everywhere off.
    @Test func retickingAtrackKeepsTheSlotsThatAreOffEverywhere() {
        var selection = fullyTicked()
        selection.toggle(track: 3)
        selection.toggle(pattern: 5)

        selection.toggle(track: 3)

        let kept = everySlot.subtracting([5])
        #expect(selection.selectedCells == [1: kept, 2: kept, 3: kept, 4: kept])
        #expect(selection.exclusionNote == "Excluded: pattern slot 5")
    }

    /// The mirror of it: bringing a slot back leaves the track that is off off.
    @Test func retickingAslotKeepsTheTrackThatIsOff() {
        var selection = fullyTicked()
        selection.toggle(track: 3)
        selection.toggle(pattern: 5)

        selection.toggle(pattern: 5)

        #expect(selection.selectedCells == [1: everySlot, 2: everySlot, 4: everySlot])
        #expect(selection.exclusionNote == "Excluded: Track 3")
    }

    /// Nothing ticked is a state to get out of: a header click reaches the whole row again.
    @Test func arowClickedFromNothingTickedComesBackWhole() {
        var selection = fullyTicked()
        for track in 1...4 { selection.toggle(track: track) }

        selection.toggle(track: 2)

        #expect(selection.state(ofTrack: 2) == .on)
        #expect(selection.selectedCells == [2: everySlot])
        #expect(selection.blockReason == nil)
    }

    @Test func apartlyTickedRowAndColumnReadAsMixed() {
        var selection = fullyTicked()

        selection.toggle(track: 2, pattern: 4)

        #expect(selection.state(ofTrack: 2) == .mixed)
        #expect(selection.state(ofPattern: 4) == .mixed)
        #expect(selection.state(ofTrack: 1) == .on)
        #expect(selection.state(ofPattern: 5) == .on)
        #expect(!selection.isTicked(track: 2))
        #expect(!selection.isTicked(pattern: 4))
    }

    @Test func awholeRowTogglesOffAndBackOn() {
        var selection = fullyTicked()

        selection.toggle(track: 4)
        #expect(selection.state(ofTrack: 4) == .off)

        selection.toggle(track: 4)
        #expect(selection.state(ofTrack: 4) == .on)
    }

    /// A mixed header ticks the rest of itself, so a click never takes away more than it shows.
    @Test func amixedRowTicksTheRestOfItself() {
        var selection = fullyTicked()
        selection.toggle(track: 2, pattern: 4)

        selection.toggle(track: 2)

        #expect(selection.state(ofTrack: 2) == .on)
        #expect(selection.selectedCells.isEmpty)
    }

    @Test func amixedColumnTicksTheRestOfItself() {
        var selection = fullyTicked()
        selection.toggle(track: 2, pattern: 4)

        selection.toggle(pattern: 4)

        #expect(selection.state(ofPattern: 4) == .on)
        #expect(selection.selectedCells.isEmpty)
    }

    /// The names come from the summary, so the note reads the way the grid and the `.mid` do.
    @Test func adrumTrackIsNamedTheWayTheGridNamesIt() {
        var selection = GridSelection(syntheticSummary(drumTracks: [1]))

        selection.toggle(track: 1)

        #expect(selection.exclusionNote == "Excluded: Track 1 (drum)")
    }

    /// Two tracks under one number must draw a grid rather than trap the app.
    @Test func aduplicateTrackNumberDoesNotTrap() {
        let track = TrackSummary(
            number: 1, name: "Track 1", mode: .sequencer,
            patterns: (1...16).map {
                PatternSummary(
                    number: $0, mode: .empty, noteCount: 0, enabledNoteCount: 0, stepCount: 16,
                    hasData: false, chain: [])
            })
        var selection = GridSelection(
            ProjectSummary(
                sourceName: "twins.KeyStepPro", tempoBPM: 120, globalSwingPercent: 50,
                currentScene: 1, tracks: [track, track]))

        selection.toggle(pattern: 5)

        #expect(selection.exclusionNote == "Excluded: pattern slot 5")
    }

    @Test func severalExcludedTracksAreAllNamed() {
        var selection = fullyTicked()

        selection.toggle(track: 1)
        selection.toggle(track: 3)

        #expect(selection.selectedCells == [2: everySlot, 4: everySlot])
        #expect(selection.exclusionNote == "Excluded: Track 1, Track 3")
    }
}
