import Foundation
import KSPRun
import Testing

@testable import KSPApp

/// The tick rule: what an export runs over, and why Convert is sometimes off.
///
/// `select` keeps the cross product of the two sets, so the only selection the core can express is
/// a rectangle. These tests hold both halves of that: the projections a rectangle sends, and the
/// reason a non-rectangle is refused rather than quietly widened.
@Suite struct GridSelectionTests {
    /// Four tracks, sixteen slots, everything ticked -- the state a fresh drop starts in.
    private func fullyTicked() -> GridSelection { GridSelection(syntheticSummary()) }

    /// The default has to be byte-identical to converting without the grid at all, and on the CLI
    /// that is spelled with two empty sets.
    @Test func everythingTickedSelectsEverythingByAskingForNothing() {
        let selection = fullyTicked()

        #expect(selection.selectedTracks.isEmpty)
        #expect(selection.selectedPatterns.isEmpty)
        #expect(selection.blockReason == nil)
        #expect(selection.exclusionNote == nil)
        #expect(selection.isTicked(track: 1, pattern: 1))
        #expect(selection.isTicked(track: 4, pattern: 16))
    }

    /// A grid with no project behind it is inert: nothing to tick, and nothing to complain about.
    @Test func afreshSelectionWithoutAProjectBlocksNothing() {
        let selection = GridSelection()

        #expect(selection.selectedTracks.isEmpty)
        #expect(selection.selectedPatterns.isEmpty)
        #expect(selection.blockReason == nil)
        #expect(selection.exclusionNote == nil)
    }

    @Test func untickingATrackLeavesTheOtherThreeAndEverySlot() {
        var selection = fullyTicked()

        selection.toggle(track: 3)

        #expect(selection.selectedTracks == [1, 2, 4])
        // Every slot is still ticked, and an axis that is whole is asked for the way the CLI asks
        // for one: not at all.
        #expect(selection.selectedPatterns.isEmpty)
        #expect(selection.blockReason == nil)
        #expect(selection.exclusionNote == "Excluded: Track 3")
        #expect(!selection.isTicked(track: 3, pattern: 1))
        #expect(selection.isTicked(track: 2, pattern: 1))
    }

    @Test func untickingApatternSlotLeavesFifteen() {
        var selection = fullyTicked()

        selection.toggle(pattern: 5)

        #expect(selection.selectedTracks.isEmpty)
        #expect(selection.selectedPatterns == Set(1...16).subtracting([5]))
        #expect(selection.blockReason == nil)
        #expect(selection.exclusionNote == "Excluded: pattern slot 5")
    }

    /// A row and a column crossing each other is still a rectangle -- that is the shape `select`
    /// keeps, so it must not be refused.
    @Test func untickingArowAndAColumnIsStillArectangle() {
        var selection = fullyTicked()

        selection.toggle(track: 3)
        selection.toggle(pattern: 5)
        selection.toggle(pattern: 6)

        #expect(selection.selectedTracks == [1, 2, 4])
        #expect(selection.selectedPatterns == Set(1...16).subtracting([5, 6]))
        #expect(selection.blockReason == nil)
        #expect(selection.exclusionNote == "Excluded: Track 3 · pattern slots 5, 6")
    }

    /// The structural fact this whole type turns on: one cell alone has no export that matches it,
    /// so Convert goes off and says which slot and which track disagree.
    @Test func untickingOneCellBlocksConvertAndNamesTheConflict() {
        var selection = fullyTicked()

        selection.toggle(track: 1, pattern: 3)

        let reason = selection.blockReason
        #expect(
            reason == "Pattern slot 3 is off for Track 1 but on for Track 2. "
                + "A slot has to be excluded on every track or on none.")
        // The projections would widen the export back to the whole project, which is exactly why
        // the block exists rather than the selection being sent as-is.
        #expect(selection.selectedTracks.isEmpty)
        #expect(selection.selectedPatterns.isEmpty)
        #expect(selection.exclusionNote == nil)
    }

    /// Untick the same slot on every track and the conflict is gone -- it is a column again.
    @Test func untickingThatSlotOnEveryTrackClearsTheBlock() {
        var selection = fullyTicked()

        for track in 1...4 { selection.toggle(track: track, pattern: 3) }

        #expect(selection.blockReason == nil)
        #expect(selection.selectedPatterns == Set(1...16).subtracting([3]))
    }

    @Test func untickingEverythingSaysSoRatherThanConvertingNothing() {
        var selection = fullyTicked()

        for track in 1...4 { selection.toggle(track: track) }

        #expect(
            selection.blockReason == "Nothing is ticked. Tick at least one pattern slot to convert."
        )
    }

    /// Re-ticking has to land back on the default exactly, or the app stops matching the CLI on
    /// defaults after a stray click.
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
        #expect(selection.selectedTracks.isEmpty)
        #expect(selection.selectedPatterns.isEmpty)
        #expect(selection.blockReason == nil)
    }

    /// A slot excluded on every track must not leave every row reading as half-ticked -- a
    /// rectangle's rows and columns are whole, and a header that says otherwise would undo the
    /// other axis on the next click.
    @Test func arectanglesRowsAndColumnsStillReadAsWhole() {
        var selection = fullyTicked()

        selection.toggle(track: 3)
        selection.toggle(pattern: 5)

        #expect(selection.state(ofTrack: 1) == .on)
        #expect(selection.state(ofTrack: 3) == .off)
        #expect(selection.state(ofPattern: 5) == .off)
        #expect(selection.state(ofPattern: 6) == .on)
    }

    /// Bringing a track back leaves the slot that is off everywhere off, so one click cannot undo
    /// the other axis behind the user's back.
    @Test func retickingAtrackKeepsTheSlotsThatAreOffEverywhere() {
        var selection = fullyTicked()
        selection.toggle(track: 3)
        selection.toggle(pattern: 5)

        selection.toggle(track: 3)

        #expect(selection.selectedTracks.isEmpty)
        #expect(selection.selectedPatterns == Set(1...16).subtracting([5]))
        #expect(selection.blockReason == nil)
        #expect(selection.exclusionNote == "Excluded: pattern slot 5")
    }

    /// The mirror of it: bringing a slot back leaves the track that is off off.
    @Test func retickingAslotKeepsTheTrackThatIsOff() {
        var selection = fullyTicked()
        selection.toggle(track: 3)
        selection.toggle(pattern: 5)

        selection.toggle(pattern: 5)

        #expect(selection.selectedTracks == [1, 2, 4])
        #expect(selection.selectedPatterns.isEmpty)
        #expect(selection.blockReason == nil)
        #expect(selection.exclusionNote == "Excluded: Track 3")
    }

    /// Nothing ticked is a state to be got out of: a header click has to reach the whole row again
    /// rather than the nothing that is left in play.
    @Test func arowClickedFromNothingTickedComesBackWhole() {
        var selection = fullyTicked()
        for track in 1...4 { selection.toggle(track: track) }

        selection.toggle(track: 2)

        #expect(selection.state(ofTrack: 2) == .on)
        #expect(selection.selectedTracks == [2])
        #expect(selection.selectedPatterns.isEmpty)
        #expect(selection.blockReason == nil)
    }

    /// A header that is neither on nor off has to read as neither, so a whole-row toggle is not
    /// mistaken for the row's actual state.
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

    /// A mixed header ticks the rest of its row rather than clearing what is left, so a click never
    /// takes away more than it shows.
    @Test func amixedRowTicksTheRestOfItself() {
        var selection = fullyTicked()
        selection.toggle(track: 2, pattern: 4)

        selection.toggle(track: 2)

        #expect(selection.state(ofTrack: 2) == .on)
        #expect(selection.selectedTracks.isEmpty)
    }

    @Test func amixedColumnTicksTheRestOfItself() {
        var selection = fullyTicked()
        selection.toggle(track: 2, pattern: 4)

        selection.toggle(pattern: 4)

        #expect(selection.state(ofPattern: 4) == .on)
        #expect(selection.selectedPatterns.isEmpty)
    }

    /// The names come from the summary, so the reason and the note read the way the exported `.mid`
    /// and the grid's own labels do.
    @Test func adrumTrackIsNamedTheWayTheGridNamesIt() {
        var selection = GridSelection(syntheticSummary(drumTracks: [1]))

        selection.toggle(track: 1)

        #expect(selection.exclusionNote == "Excluded: Track 1 (drum)")
    }

    /// The reader hands over whatever the file holds, so two tracks under one number must draw a
    /// grid rather than trap the app.
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

        #expect(selection.selectedPatterns == Set(1...16).subtracting([5]))
        #expect(selection.exclusionNote == "Excluded: pattern slot 5")
    }

    @Test func severalExcludedTracksAreAllNamed() {
        var selection = fullyTicked()

        selection.toggle(track: 1)
        selection.toggle(track: 3)

        #expect(selection.selectedTracks == [2, 4])
        #expect(selection.exclusionNote == "Excluded: Track 1, Track 3")
    }
}
