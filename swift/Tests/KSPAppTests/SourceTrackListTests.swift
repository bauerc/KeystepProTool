import Foundation
import KSPKit
import KSPRun
import Testing

@testable import KSPApp

@Suite struct SourceTrackListTests {
    @Test func atrackCarriesItsNameCountsAndChannel() {
        let list = SourceTrackList(
            syntheticSong(tracks: [sourceTrack(1, name: "Piano", noteCount: 128, bars: 4)]))

        let row = list.rows[0]
        #expect(row.number == 1)
        #expect(row.name == "Piano")
        #expect(row.channels == "ch 1")
        #expect(row.counts == "128 notes · 4 bars")
        #expect(!row.isEmpty)
        #expect(row.badge == nil)
    }

    @Test func atrackTheFileNamesNoneIsNumberedInstead() {
        let list = SourceTrackList(syntheticSong(tracks: [sourceTrack(3)]))

        #expect(list.rows[0].name == "Track 3")
    }

    @Test func asingleNoteInASingleBarIsNotPluralised() {
        let list = SourceTrackList(
            syntheticSong(tracks: [sourceTrack(1, noteCount: 1, bars: 1)]))

        #expect(list.rows[0].counts == "1 note · 1 bar")
    }

    @Test func atrackHoldingNothingSaysSoRatherThanCountingZero() {
        let list = SourceTrackList(
            syntheticSong(tracks: [sourceTrack(1, name: "Mute", noteCount: 0)]))

        let row = list.rows[0]
        #expect(row.isEmpty)
        #expect(row.counts == "no notes")
        #expect(row.channels == "—")
        #expect(row.detail == "Source track 1 holds no notes, so nothing is imported from it.")
    }

    /// The reader names the drum track; a percussion track it did not name is imported melodically.
    @Test func thedrumTrackTheReaderNamedIsTheOneBadgedDrums() {
        let list = SourceTrackList(
            syntheticSong(tracks: [
                sourceTrack(1, name: "Bass"),
                sourceTrack(2, name: "Kit", channels: [10], isDrumTrack: true),
                sourceTrack(3, name: "Shaker", channels: [10]),
            ]))

        #expect(list.rows[0].badge == nil)
        #expect(list.rows[1].badge == .drums)
        #expect(list.rows[2].badge == .percussion)
        #expect(list.rows[1].detail.contains("becomes the drum track"))
        #expect(list.rows[2].detail.contains("imported melodically"))
    }

    /// Only the channel 10 part of a split track is the drum track, and the badge cannot say so.
    @Test func asplitDrumTrackGivesUpOnlyItsChannelTenPart() {
        let list = SourceTrackList(
            syntheticSong(tracks: [
                sourceTrack(1, name: "Everything", channels: [1, 10], isDrumTrack: true)
            ]))

        #expect(list.rows[0].badge == .drums)
        #expect(list.rows[0].detail.contains("that part of this one becomes the drum track"))
        #expect(list.rows[0].detail.contains("Each channel becomes a device track of its own."))
    }

    @Test func atrackOnSeveralChannelsNamesThemAllAndSaysItSplits() {
        let list = SourceTrackList(
            syntheticSong(tracks: [sourceTrack(1, name: "Strings", channels: [2, 3])]))

        #expect(list.rows[0].channels == "ch 2, 3")
        #expect(list.rows[0].detail.contains("Each channel becomes a device track of its own."))
    }

    @Test func theconductorTrackIsBadgedRatherThanLeftLookingEmpty() {
        let list = SourceTrackList(
            syntheticSong(tracks: [
                sourceTrack(1, name: "My Song", noteCount: 0, isConductor: true),
                sourceTrack(2, name: "Lead"),
            ]))

        #expect(list.rows[0].badge == .tempo)
        #expect(list.rows[0].counts == "no notes")
        #expect(
            list.rows[0].detail
                == "Source track 1 carries the file's tempo and time signature, not notes, so "
                + "nothing is imported from it.")
        #expect(list.rows[1].badge == nil)
    }

    @Test func abadgeReadsAsTheAppElsewhereNamesTheDestination() {
        #expect(SourceTrackList.Badge.drums.text == "Drums")
        #expect(SourceTrackList.Badge.percussion.text == "Percussion")
        #expect(SourceTrackList.Badge.tempo.text == "Tempo")
    }

    @Test func theheaderNamesTheTempoTheBarAndHowManyTracksThereAre() {
        let list = SourceTrackList(
            syntheticSong(tracks: [sourceTrack(1), sourceTrack(2), sourceTrack(3)]))

        #expect(list.header == "120 BPM · 4 beats to the bar · 3 source tracks")
    }

    @Test func awholeNumberedTempoLosesItsDecimal() {
        let straight = SourceTrackList(syntheticSong(tempoBPM: 120, tracks: [sourceTrack(1)]))
        let fractional = SourceTrackList(syntheticSong(tempoBPM: 92.5, tracks: [sourceTrack(1)]))

        #expect(straight.header.hasPrefix("120 BPM"))
        #expect(fractional.header.hasPrefix("92.5 BPM"))
    }

    @Test func onesourceTrackIsNotPluralised() {
        let list = SourceTrackList(syntheticSong(tracks: [sourceTrack(1)]))

        #expect(list.header.hasSuffix("1 source track"))
    }

    @Test func thepreFlightNoteCarriesWhatTheReadFound() {
        let collector = Collector()
        collector.add(.trackSplitByChannel, "source track(s) 1 carry more than one channel")
        let list = SourceTrackList(
            syntheticSong(
                tracks: [sourceTrack(1, channels: [1, 10])],
                diagnostics: collector.report()))

        #expect(list.note(verbose: false)?.contains("more than one channel") == true)
        #expect(list.note(verbose: true)?.contains("more than one channel") == true)
    }

    @Test func anuneventfulFileHasNoPreFlightNote() {
        let list = SourceTrackList(syntheticSong(tracks: [sourceTrack(1)]))

        #expect(list.note(verbose: false) == nil)
        #expect(list.note(verbose: true) == nil)
    }

    /// The staged pane scrolls vertically only, so anything wider than it is silently clipped.
    /// Measured at the window's floor, which is the one width the user cannot resize away from.
    @Test func thelistFitsTheStagedPaneWithoutTruncatingARow() {
        #expect(AppLayout.trackRowWidth <= AppLayout.minimumContentWidth)
    }

    /// A column drawn but left out of ``AppLayout/trackColumnWidths`` leaves the fit above
    /// asserting nothing, which is how the destination picker came to hang 110 pt off the pane.
    @Test func everyColumnTheRowDrawsIsInTheWidthItIsHeldTo() {
        #expect(AppLayout.trackColumnWidths.count == 7)
        #expect(AppLayout.trackColumnWidths.contains(AppLayout.trackDestinationWidth))
    }

    @Test func thewindowNeverOpensSmallerThanItCanBeDraggedTo() {
        #expect(AppLayout.minimumWindowWidth <= AppLayout.defaultWindowWidth)
        #expect(AppLayout.minimumWindowHeight <= AppLayout.defaultWindowHeight)
    }

    @Test func areadFileListsEveryTrackItHoldsWhetherOrNotItHoldsNotes() throws {
        let list = SourceTrackList(try summariseSong("test_file.mid"))

        #expect(!list.rows.isEmpty)
        #expect(list.rows.map(\.number) == Array(1...list.rows.count))
        #expect(list.rows.allSatisfy { !$0.name.isEmpty })
        #expect(list.rows.contains { !$0.isEmpty })
    }
}
