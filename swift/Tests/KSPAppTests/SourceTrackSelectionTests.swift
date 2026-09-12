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

    @Test func tickingNothingDisablesConvertWithAReason() {
        var selection = SourceTrackSelection(syntheticSong(tracks: [sourceTrack(1)]))

        selection.toggle(1)

        #expect(
            selection.blockReason(drumSense(selection))
                == "Nothing is ticked. Tick at least one source track to convert."
        )
    }

    @Test func tickingOnlyTracksThatHoldNothingDisablesConvertToo() {
        var selection = SourceTrackSelection(
            syntheticSong(tracks: [sourceTrack(1), sourceTrack(2, noteCount: 0)]))

        selection.toggle(1)
        selection.toggle(2)

        #expect(
            selection.blockReason(drumSense(selection))
                == "No ticked source track holds notes, so nothing would be written.")
    }

    @Test func fourticksFitTheDeviceAndSayNothing() {
        let selection = SourceTrackSelection(syntheticSong(tracks: (1...4).map { sourceTrack($0) }))

        #expect(selection.overflowNote == nil)
        #expect(selection.blockReason(drumSense(selection)) == nil)
        #expect(selection.exclusionNote == nil)
    }

    @Test func afifthTickIsFlaggedRatherThanRefused() {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...5).map { sourceTrack($0) }))

        selection.toggle(5)

        #expect(selection.isTicked(5))
        #expect(selection.overflowNote == "That needs 5 device tracks, so 1 would be dropped.")
        #expect(selection.blockReason(drumSense(selection)) == nil)
    }

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

    @Test func anemptyTickSetAsksTheRunnerForNothing() {
        var selection = SourceTrackSelection(syntheticSong(tracks: [sourceTrack(1)]))

        selection.toggle(1)

        #expect(selection.spec == nil)
        #expect(selection.blockReason(drumSense(selection)) != nil)
    }

    @Test func aselectionWithNothingToTickSaysNothingAtAll() {
        let selection = SourceTrackSelection()

        #expect(selection.overflowNote == nil)
        #expect(selection.blockReason(drumSense(selection)) == nil)
        #expect(selection.exclusionNote == nil)
        #expect(selection.spec == nil)
    }

    /// Six tracks, two of them silent, so the four that hold notes all fit.
    @Test func areadFileTicksTheTracksThatHoldNotes() throws {
        let selection = SourceTrackSelection(try summariseSong("m6-test-file.mid"))

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

    @Test func twotracksOnOneDeviceTrackDisableConvertWithAReason() {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...4).map { sourceTrack($0) }))

        selection.send(2, to: .track(3))
        selection.send(4, to: .track(3))

        #expect(
            selection.blockReason(drumSense(selection))
                == "Source tracks 2 and 4 are both sent to Track 3; one device track holds one "
                + "source track.")
    }

    @Test func asecondTrackSetToDrumsClashesOverDeviceTrackOne() {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...4).map { sourceTrack($0) }))

        selection.send(1, to: .drums)
        selection.send(2, to: .drums)

        #expect(
            selection.blockReason(drumSense(selection))
                == "Source tracks 1 and 2 are both sent to Drums; one device track holds one "
                + "source track.")
    }

    @Test func thedrumTrackMayNotBeSentAnywhereButTrackOne() {
        var selection = SourceTrackSelection(
            syntheticSong(tracks: [
                sourceTrack(1), sourceTrack(2, channels: [10], isDrumTrack: true), sourceTrack(3),
                sourceTrack(4),
            ]))

        selection.send(2, to: .track(3))

        #expect(
            selection.blockReason(drumSense(selection))
                == "Source track 2 is the drum track, so it can only go to Track 1; only device "
                + "track 1 carries a drum set.")

        selection.send(2, to: .track(1))
        #expect(selection.blockReason(drumSense(selection)) == nil)
    }

    @Test func adetectedDrumTrackHoldsDeviceTrackOneAgainstARoute() {
        var selection = SourceTrackSelection(
            syntheticSong(tracks: [
                sourceTrack(1, channels: [10], isDrumTrack: true), sourceTrack(2), sourceTrack(3),
                sourceTrack(4),
            ]))

        selection.send(3, to: .track(1))

        #expect(
            selection.blockReason(drumSense(selection))
                == "Source track 3 is sent to Track 1, which source track 1 holds as the drum "
                + "track; only device track 1 carries a drum set.")
    }

    @Test func skippingOneDrumTrackPromotesTheNextToHoldTrackOne() {
        var selection = SourceTrackSelection(
            syntheticSong(tracks: [
                sourceTrack(1, channels: [10], isDrumTrack: true), sourceTrack(2, channels: [10]),
                sourceTrack(3), sourceTrack(4),
            ]))

        selection.send(1, to: .skip)
        selection.send(3, to: .track(1))

        #expect(
            selection.blockReason(drumSense(selection))
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

        #expect(selection.blockReason(drumSense(selection)) == nil)
        #expect(selection.routeSpec == "3:1")
    }

    @Test func takingNothingAsDrumsLeavesDeviceTrackOneFree() {
        var selection = SourceTrackSelection(
            syntheticSong(tracks: [
                sourceTrack(1, channels: [10], isDrumTrack: true), sourceTrack(2), sourceTrack(3),
                sourceTrack(4),
            ]))
        selection.send(3, to: .track(1))
        var settings = Settings()
        settings.drums = .none

        #expect(selection.blockReason(drumSense(selection)) != nil)
        #expect(selection.blockReason(drumSense(selection, settings)) == nil)
    }

    @Test func aroutingAllowedUnderNoneIsOneTheCoreAccepts() throws {
        var selection = SourceTrackSelection(
            syntheticSong(tracks: [
                sourceTrack(1, channels: [10], isDrumTrack: true), sourceTrack(2), sourceTrack(3),
                sourceTrack(4),
            ]))
        selection.send(3, to: .track(1))
        var settings = Settings()
        settings.drums = .none
        #expect(selection.blockReason(drumSense(selection, settings)) == nil)

        let options = try ImportOptions(
            midiTracks: [1, 2, 3, 4], drumTrack: .none,
            routes: try resolveRoutes(nil, selection.routeSpec))

        #expect(options.drumTrack == .none)
        #expect(options.routes == [TrackRoute(source: 3, device: 1)])
    }

    @Test func thedrumFallbackFollowsTheChosenChannel() {
        var selection = SourceTrackSelection(
            syntheticSong(tracks: [
                sourceTrack(1, channels: [10]), sourceTrack(2, channels: [3]), sourceTrack(3),
                sourceTrack(4),
            ]))
        selection.send(3, to: .track(1))
        var settings = Settings()
        settings.drumChannel = 3

        #expect(
            selection.blockReason(drumSense(selection, settings))
                == "Source track 3 is sent to Track 1, which source track 2 holds as the drum "
                + "track; only device track 1 carries a drum set.")
    }

    @Test func aplacedTrackOnTwoChannelsAsksForOneDeviceTrack() {
        var selection = SourceTrackSelection(
            syntheticSong(tracks: [
                sourceTrack(1, channels: [1, 2]), sourceTrack(2), sourceTrack(3), sourceTrack(4),
            ]))
        #expect(selection.overflowNote == "That needs 5 device tracks, so 1 would be dropped.")

        selection.send(1, to: .track(1))

        #expect(selection.overflowNote == nil)
    }

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
        #expect(selection.blockReason(drumSense(selection)) != nil)

        #expect(throws: KSPError.self) {
            _ = try ImportOptions(
                midiTracks: [1, 2, 3, 4],
                drumTrack: selection.drumTrack.map(DrumDesignation.source) ?? .auto,
                routes: try resolveRoutes(nil, selection.routeSpec))
        }
    }

    @Test func asecondDrumsIsRefusedHereBecauseTheCoreCannotSpellIt() throws {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...4).map { sourceTrack($0) }))
        selection.send(1, to: .drums)
        selection.send(2, to: .drums)
        #expect(selection.blockReason(drumSense(selection)) != nil)

        let options = try ImportOptions(
            midiTracks: [1, 2, 3, 4],
            drumTrack: selection.drumTrack.map(DrumDesignation.source) ?? .auto,
            routes: try resolveRoutes(nil, selection.routeSpec))

        #expect(options.drumTrack == .source(1))
    }

    @Test func aroutingTheAppAllowsIsOneTheCoreAccepts() throws {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...4).map { sourceTrack($0) }))
        selection.send(3, to: .track(2))
        selection.send(4, to: .drums)
        #expect(selection.blockReason(drumSense(selection)) == nil)

        let options = try ImportOptions(
            midiTracks: [1, 2, 3, 4],
            drumTrack: selection.drumTrack.map(DrumDesignation.source) ?? .auto,
            routes: try resolveRoutes(nil, selection.routeSpec))

        #expect(options.routes == [TrackRoute(source: 3, device: 2)])
        #expect(options.drumTrack == .source(4))
    }

    @Test func adestinationNamesTheDeviceTrackItsColourComesFrom() {
        #expect(SourceTrackSelection.Destination.track(3).device == 3)
        #expect(SourceTrackSelection.Destination.drums.device == 1)
        #expect(SourceTrackSelection.Destination.automatic.device == nil)
        #expect(SourceTrackSelection.Destination.skip.device == nil)
    }

    @Test func everyDestinationInTheMenuNamesAtMostOneDeviceTrack() {
        let named = SourceTrackSelection.destinations.compactMap(\.device)

        #expect(named.allSatisfy { (1...Constants.trackItemIDs.count).contains($0) })
        #expect(named.count == Constants.trackItemIDs.count + 1)
    }
}
