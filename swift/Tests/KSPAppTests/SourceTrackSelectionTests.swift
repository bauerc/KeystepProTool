import Foundation
import KSPKit
import KSPRun
import Testing

@testable import KSPApp

@Suite struct SourceTrackSelectionTests {
    @Test func thefirstFourNoteBearingTracksStartTicked() {
        let selection = SourceTrackSelection(syntheticSong(tracks: (1...6).map { sourceTrack($0) }))

        #expect((1...4).allSatisfy { selection.isTicked($0) })
        #expect(!selection.isTicked(5))
        #expect(!selection.isTicked(6))
    }

    @Test func atrackHoldingNothingIsPassedOverWhenTheDefaultIsPicked() {
        let selection = SourceTrackSelection(
            syntheticSong(tracks: [
                sourceTrack(1), sourceTrack(2, noteCount: 0), sourceTrack(3), sourceTrack(4),
                sourceTrack(5), sourceTrack(6),
            ]))

        #expect(!selection.isTicked(2))
        #expect([1, 3, 4, 5].allSatisfy { selection.isTicked($0) })
        #expect(!selection.isTicked(6))
    }

    /// A track that produces no clip asks nothing of the device, so ticking one is free.
    @Test func anemptyTrackCanStillBeTickedAndCostsNoDeviceTrack() {
        var selection = SourceTrackSelection(
            syntheticSong(tracks: (1...4).map { sourceTrack($0) } + [sourceTrack(5, noteCount: 0)]))

        selection.toggle(5)

        #expect(selection.isTicked(5))
        #expect(selection.overflowNote == nil)
    }

    @Test func tickingTurnsATrackOffAndBackOn() {
        var selection = SourceTrackSelection(syntheticSong(tracks: [sourceTrack(1)]))

        selection.toggle(1)
        #expect(!selection.isTicked(1))
        selection.toggle(1)
        #expect(selection.isTicked(1))
    }

    @Test func thecountLineStatesTheTicksAgainstTheDevicesFourTracks() {
        let selection = SourceTrackSelection(syntheticSong(tracks: (1...6).map { sourceTrack($0) }))

        #expect(selection.countLine == "4 of 6 source tracks ticked; the device has 4 tracks.")
    }

    @Test func onesourceTrackIsNotPluralised() {
        let selection = SourceTrackSelection(syntheticSong(tracks: [sourceTrack(1)]))

        #expect(selection.countLine == "1 of 1 source track ticked; the device has 4 tracks.")
    }

    @Test func tickingNothingDisablesConvertWithAReason() {
        var selection = SourceTrackSelection(syntheticSong(tracks: [sourceTrack(1)]))

        selection.toggle(1)

        #expect(
            selection.blockReason == "Nothing is ticked. Tick at least one source track to convert."
        )
    }

    /// The runner would otherwise refuse this itself, after the read, with "no notes to convert".
    @Test func tickingOnlyTracksThatHoldNothingDisablesConvertToo() {
        var selection = SourceTrackSelection(
            syntheticSong(tracks: [sourceTrack(1), sourceTrack(2, noteCount: 0)]))

        selection.toggle(1)
        selection.toggle(2)

        #expect(
            selection.blockReason
                == "No ticked source track holds notes, so nothing would be written.")
    }

    @Test func fourticksFitTheDeviceAndSayNothing() {
        let selection = SourceTrackSelection(syntheticSong(tracks: (1...4).map { sourceTrack($0) }))

        #expect(selection.overflowNote == nil)
        #expect(selection.blockReason == nil)
        #expect(selection.exclusionNote == nil)
    }

    @Test func afifthTickIsFlaggedRatherThanRefused() {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...5).map { sourceTrack($0) }))

        selection.toggle(5)

        #expect(selection.isTicked(5))
        #expect(selection.overflowNote == "That needs 5 device tracks, so 1 would be dropped.")
        #expect(selection.blockReason == nil)
    }

    /// A source track carrying several channels becomes a device track per channel, so the ticks
    /// and the device tracks they ask for are not the same count.
    @Test func atickedTrackOnTwoChannelsCountsTwiceTowardsTheDevicesFour() {
        let selection = SourceTrackSelection(
            syntheticSong(tracks: [
                sourceTrack(1, channels: [1, 2]), sourceTrack(2), sourceTrack(3), sourceTrack(4),
            ]))

        #expect(selection.overflowNote == "That needs 5 device tracks, so 1 would be dropped.")
    }

    @Test func tickingEveryTrackThatHoldsNotesReadsAsAllOfThem() {
        var selection = SourceTrackSelection(
            syntheticSong(tracks: [sourceTrack(1), sourceTrack(2), sourceTrack(3, noteCount: 0)]))

        #expect(selection.spec == nil)
        selection.toggle(2)
        #expect(selection.spec == "1")
    }

    @Test func aselectionIsSpeltAsTheOptionTheCLITakes() throws {
        let selection = SourceTrackSelection(syntheticSong(tracks: (1...6).map { sourceTrack($0) }))

        #expect(selection.spec == "1,2,3,4")
        #expect(try resolveMidiTracks(nil, selection.spec) == [1, 2, 3, 4])
    }

    @Test func theexclusionNoteNamesWhatWasLeftOutAndIgnoresTheSilent() {
        let selection = SourceTrackSelection(
            syntheticSong(tracks: [
                sourceTrack(1, name: "Bass"), sourceTrack(2, name: "Keys"),
                sourceTrack(3, name: "Lead"), sourceTrack(4, name: "Pad"),
                sourceTrack(5, name: "Strings"), sourceTrack(6, noteCount: 0),
            ]))

        #expect(selection.exclusionNote == "Excluded: Strings")
    }

    @Test func atrackTheFileNamesNoneIsExcludedByItsNumber() {
        let selection = SourceTrackSelection(syntheticSong(tracks: (1...5).map { sourceTrack($0) }))

        #expect(selection.exclusionNote == "Excluded: Track 5")
    }

    /// No tick spells no valid `--midi-tracks`, and `blockReason` has already refused the run.
    @Test func anemptyTickSetAsksTheRunnerForNothing() {
        var selection = SourceTrackSelection(syntheticSong(tracks: [sourceTrack(1)]))

        selection.toggle(1)

        #expect(selection.spec == nil)
        #expect(selection.blockReason != nil)
    }

    @Test func aselectionWithNothingToTickSaysNothingAtAll() {
        let selection = SourceTrackSelection()

        #expect(selection.countLine == nil)
        #expect(selection.overflowNote == nil)
        #expect(selection.blockReason == nil)
        #expect(selection.exclusionNote == nil)
        #expect(selection.spec == nil)
    }

    /// Six tracks, two of them silent, so the four that hold notes all fit.
    @Test func areadFileTicksTheTracksThatHoldNotes() throws {
        let selection = SourceTrackSelection(try summariseSong("m6-test-file.mid"))

        #expect(selection.countLine == "4 of 6 source tracks ticked; the device has 4 tracks.")
        #expect([3, 4, 5, 6].allSatisfy { selection.isTicked($0) })
        #expect(selection.spec == nil)
        #expect(selection.overflowNote == nil)
    }
}
