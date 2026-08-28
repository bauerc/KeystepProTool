import Foundation
import KSPKit
import KSPMIDI
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

    @Test func atrackStartsOnTheAutomaticAssignmentAndAsksForNoOption() {
        let selection = SourceTrackSelection(syntheticSong(tracks: (1...4).map { sourceTrack($0) }))

        #expect((1...4).allSatisfy { selection.destination($0) == .automatic })
        #expect(selection.routeSpec == nil)
        #expect(selection.drumTrack == nil)
    }

    @Test func adestinationIsSpeltAsTheOptionTheCLITakes() throws {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...4).map { sourceTrack($0) }))

        selection.send(3, to: .track(1))

        #expect(selection.destination(3) == .track(1))
        #expect(selection.routeSpec == "3:1")
        #expect(try resolveRoutes(nil, selection.routeSpec) == [TrackRoute(source: 3, device: 1)])
    }

    /// Only the tracks placed by hand: routing one merges its channels onto a single device track,
    /// so routing the rest to where they already are would move them.
    @Test func thetracksLeftOnAutomaticStayOutOfTheRoute() {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...4).map { sourceTrack($0) }))

        selection.send(4, to: .track(2))
        selection.send(2, to: .track(3))

        #expect(selection.routeSpec == "2:3,4:2")
    }

    @Test func drumsAreTheDrumTrackOptionRatherThanARoute() {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...4).map { sourceTrack($0) }))

        selection.send(2, to: .drums)

        #expect(selection.drumTrack == 2)
        #expect(selection.routeSpec == nil)
    }

    @Test func skipUnticksTheTrackAndReadsBackAsSkip() {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...5).map { sourceTrack($0) }))

        selection.send(2, to: .skip)

        #expect(!selection.isTicked(2))
        #expect(selection.destination(2) == .skip)
        #expect(selection.spec == "1,3,4")
    }

    /// The two options are read together by the core, so the app may hand over both at once.
    @Test func aroutedTrackSurvivesAnotherBeingSkipped() throws {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...5).map { sourceTrack($0) }))

        selection.send(3, to: .track(1))
        selection.send(2, to: .skip)

        #expect(selection.spec == "1,3,4")
        #expect(selection.routeSpec == "3:1")
    }

    @Test func adestinationTicksATrackThatWasNotTicked() {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...6).map { sourceTrack($0) }))

        selection.send(6, to: .track(2))

        #expect(selection.isTicked(6))
        #expect(selection.routeSpec == "6:2")
    }

    @Test func skippingKeepsTheChoiceForWhenTheTrackComesBack() {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...4).map { sourceTrack($0) }))

        selection.send(3, to: .track(4))
        selection.send(3, to: .skip)
        #expect(selection.routeSpec == nil)

        selection.toggle(3)
        #expect(selection.routeSpec == "3:4")
    }

    @Test func automaticForgetsAchoiceRatherThanPinningIt() {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...4).map { sourceTrack($0) }))

        selection.send(3, to: .track(4))
        selection.send(3, to: .automatic)

        #expect(selection.destination(3) == .automatic)
        #expect(selection.routeSpec == nil)
    }

    /// The route would be refused with exit 2, so it must not reach the runner at all.
    @Test func twotracksOnOneDeviceTrackDisableConvertWithAReason() {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...4).map { sourceTrack($0) }))

        selection.send(2, to: .track(3))
        selection.send(4, to: .track(3))

        #expect(
            selection.blockReason
                == "Source tracks 2 and 4 are both sent to Track 3; one device track holds one "
                + "source track.")
    }

    @Test func asecondTrackSetToDrumsClashesOverDeviceTrackOne() {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...4).map { sourceTrack($0) }))

        selection.send(1, to: .drums)
        selection.send(2, to: .drums)

        #expect(
            selection.blockReason
                == "Source tracks 1 and 2 are both sent to Drums; one device track holds one "
                + "source track.")
    }

    /// The reader's drum track is the assignment's, whether or not an option named it, so sending
    /// it elsewhere is refused where sending it to Track 1 is not.
    @Test func thedrumTrackMayNotBeSentAnywhereButTrackOne() {
        var selection = SourceTrackSelection(
            syntheticSong(tracks: [
                sourceTrack(1), sourceTrack(2, channels: [10], isDrumTrack: true), sourceTrack(3),
                sourceTrack(4),
            ]))

        selection.send(2, to: .track(3))

        #expect(
            selection.blockReason
                == "Source track 2 is the drum track, so it can only go to Track 1; only device "
                + "track 1 carries a drum set.")

        selection.send(2, to: .track(1))
        #expect(selection.blockReason == nil)
    }

    /// The drum track the reader found, which the assignment uses when no option names one.
    @Test func adetectedDrumTrackHoldsDeviceTrackOneAgainstARoute() {
        var selection = SourceTrackSelection(
            syntheticSong(tracks: [
                sourceTrack(1, channels: [10], isDrumTrack: true), sourceTrack(2), sourceTrack(3),
                sourceTrack(4),
            ]))

        selection.send(3, to: .track(1))

        #expect(
            selection.blockReason
                == "Source track 3 is sent to Track 1, which source track 1 holds as the drum "
                + "track; only device track 1 carries a drum set.")
    }

    /// `isDrumTrack` names the first channel 10 track of the whole file, but the assignment looks
    /// among the clips it read, so skipping that one promotes the next.
    @Test func skippingOneDrumTrackPromotesTheNextToHoldTrackOne() {
        var selection = SourceTrackSelection(
            syntheticSong(tracks: [
                sourceTrack(1, channels: [10], isDrumTrack: true), sourceTrack(2, channels: [10]),
                sourceTrack(3), sourceTrack(4),
            ]))

        selection.send(1, to: .skip)
        selection.send(3, to: .track(1))

        #expect(
            selection.blockReason
                == "Source track 3 is sent to Track 1, which source track 2 holds as the drum "
                + "track; only device track 1 carries a drum set.")
    }

    @Test func adetectedDrumTrackThatIsSkippedNoLongerHoldsTrackOne() {
        var selection = SourceTrackSelection(
            syntheticSong(tracks: [
                sourceTrack(1, channels: [10], isDrumTrack: true), sourceTrack(2), sourceTrack(3),
                sourceTrack(4),
            ]))

        selection.send(1, to: .skip)
        selection.send(3, to: .track(1))

        #expect(selection.blockReason == nil)
        #expect(selection.routeSpec == "3:1")
    }

    /// Naming a track merges its channels onto the one device track, so it stops asking for two.
    @Test func aplacedTrackOnTwoChannelsAsksForOneDeviceTrack() {
        var selection = SourceTrackSelection(
            syntheticSong(tracks: [
                sourceTrack(1, channels: [1, 2]), sourceTrack(2), sourceTrack(3), sourceTrack(4),
            ]))
        #expect(selection.overflowNote == "That needs 5 device tracks, so 1 would be dropped.")

        selection.send(1, to: .track(1))

        #expect(selection.overflowNote == nil)
    }

    /// The app words these itself, so they are pinned against the core that would refuse them:
    /// a clash the app misses reaches the runner, and one it invents blocks a legal conversion.
    @Test(
        arguments: [
            [(2, SourceTrackSelection.Destination.track(3)), (4, .track(3))],
            [(2, SourceTrackSelection.Destination.drums), (3, .track(1))],
        ])
    func aclashTheAppNamesIsOneTheCoreWouldRefuse(
        sent: [(source: Int, to: SourceTrackSelection.Destination)]
    ) throws {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...4).map { sourceTrack($0) }))
        for entry in sent { selection.send(entry.source, to: entry.to) }
        #expect(selection.blockReason != nil)

        #expect(throws: KSPError.self) {
            _ = try ImportOptions(
                midiTracks: [1, 2, 3, 4], drumTrack: selection.drumTrack,
                routes: try resolveRoutes(nil, selection.routeSpec))
        }
    }

    /// The one block the app owns outright: `--drum-track` takes a single number, so a second
    /// track set to Drums would reach the core as a melodic one and be imported without a word.
    @Test func asecondDrumsIsRefusedHereBecauseTheCoreCannotSpellIt() throws {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...4).map { sourceTrack($0) }))
        selection.send(1, to: .drums)
        selection.send(2, to: .drums)
        #expect(selection.blockReason != nil)

        let options = try ImportOptions(
            midiTracks: [1, 2, 3, 4], drumTrack: selection.drumTrack,
            routes: try resolveRoutes(nil, selection.routeSpec))

        #expect(options.drumTrack == 1)
    }

    @Test func aroutingTheAppAllowsIsOneTheCoreAccepts() throws {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...4).map { sourceTrack($0) }))
        selection.send(3, to: .track(2))
        selection.send(4, to: .drums)
        #expect(selection.blockReason == nil)

        let options = try ImportOptions(
            midiTracks: [1, 2, 3, 4], drumTrack: selection.drumTrack,
            routes: try resolveRoutes(nil, selection.routeSpec))

        #expect(options.routes == [TrackRoute(source: 3, device: 2)])
        #expect(options.drumTrack == 4)
    }
}
