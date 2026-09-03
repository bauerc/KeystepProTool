import Foundation
import KSPKit
import KSPRun
import Testing

@testable import KSPApp

/// Under the designation and the ticks the app starts on, so a test about something else need not
/// restate either.
private func list(
    _ summary: SongSummary, drums: DrumSense = gmDrums, selection: SourceTrackSelection? = nil
) -> SourceTrackList {
    SourceTrackList(
        summary, drums: drums, selection: selection ?? SourceTrackSelection(summary))
}

@Suite struct SourceTrackListTests {
    @Test func atrackCarriesItsNameCountsAndChannel() {
        let list = list(
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
        let list = list(syntheticSong(tracks: [sourceTrack(3)]))

        #expect(list.rows[0].name == "Track 3")
    }

    @Test func asingleNoteInASingleBarIsNotPluralised() {
        let list = list(
            syntheticSong(tracks: [sourceTrack(1, noteCount: 1, bars: 1)]))

        #expect(list.rows[0].counts == "1 note · 1 bar")
    }

    @Test func atrackHoldingNothingSaysSoRatherThanCountingZero() {
        let list = list(
            syntheticSong(tracks: [sourceTrack(1, name: "Mute", noteCount: 0)]))

        let row = list.rows[0]
        #expect(row.isEmpty)
        #expect(row.counts == "no notes")
        #expect(row.channels == "—")
        #expect(row.detail == "Source track 1 holds no notes, so nothing is imported from it.")
    }

    /// The reader names the drum track; a percussion track it did not name is imported melodically.
    @Test func thedrumTrackTheReaderNamedIsTheOneBadgedDrums() {
        let list = list(
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
        let list = list(
            syntheticSong(tracks: [
                sourceTrack(1, name: "Everything", channels: [1, 10], isDrumTrack: true)
            ]))

        #expect(list.rows[0].badge == .drums)
        #expect(list.rows[0].detail.contains("that part of this one becomes the drum track"))
        #expect(list.rows[0].detail.contains("Each channel becomes a device track of its own."))
    }

    /// Nothing is taken as drums, so no row may be badged and no row may say a channel is searched.
    @Test func takingNothingAsDrumsBadgesNoRow() {
        let list = list(
            syntheticSong(tracks: [
                sourceTrack(1, name: "Bass"),
                sourceTrack(2, name: "Kit", channels: [10], isDrumTrack: true),
                sourceTrack(3, name: "Shaker", channels: [10]),
            ]),
            drums: DrumSense(designation: .none, channel: 10))

        #expect(list.rows.allSatisfy { $0.badge == nil })
        #expect(list.rows.allSatisfy { !$0.detail.contains("looks for drums") })
    }

    /// The badge follows the setting, not General MIDI: a kit a DAW put on channel 3 is the one
    /// the import reads as drums once the sidebar says so.
    @Test func thebadgeFollowsTheChosenChannel() {
        let list = list(
            syntheticSong(tracks: [
                sourceTrack(1, name: "Kit", channels: [10], isDrumTrack: true),
                sourceTrack(2, name: "Logic kit", channels: [3]),
                sourceTrack(3, name: "Tambourine", channels: [3]),
            ]),
            drums: DrumSense(designation: .auto, channel: 3))

        #expect(list.rows[0].badge == nil)
        #expect(list.rows[1].badge == .drums)
        #expect(list.rows[2].badge == .percussion)
        #expect(list.rows[1].detail.contains("Channel 3 is where the import looks for drums"))
        #expect(list.rows[2].detail.contains("Channel 3 is where the import looks for drums"))
    }

    /// A named track is found without a channel search, so the row must not claim one happened.
    @Test func anamedSourceTrackIsBadgedWithoutNamingAChannel() {
        let list = list(
            syntheticSong(tracks: [
                sourceTrack(1, channels: [10], isDrumTrack: true), sourceTrack(2, name: "Kit"),
            ]),
            drums: DrumSense(designation: .source(2), channel: 10))

        #expect(list.rows[0].badge == nil)
        #expect(list.rows[1].badge == .drums)
        #expect(list.rows[1].detail.contains("sent to Drums, so it becomes the drum track"))
        #expect(!list.rows[1].detail.contains("looks for drums"))
    }

    /// The badge names the track ``SourceTrackSelection/drumSource(_:)`` names, which looks among
    /// the ticked tracks: badging one the block does not name would contradict the reason on screen.
    @Test func untickingTheFirstTrackOnTheChannelMovesTheDrumBadge() {
        let summary = syntheticSong(tracks: [
            sourceTrack(1, name: "Bass"),
            sourceTrack(2, name: "Kit", channels: [10], isDrumTrack: true),
            sourceTrack(3, name: "Shaker", channels: [10]),
        ])
        var selection = SourceTrackSelection(summary)
        selection.send(2, to: .skip)

        let list = list(summary, selection: selection)

        #expect(selection.drumSource(gmDrums) == 3)
        #expect(list.rows[1].badge == .percussion)
        #expect(list.rows[2].badge == .drums)
    }

    /// `assign` merges every clip of a named track into the one drum clip, so the row must not
    /// claim its channels each become a device track.
    @Test func anamedDrumTrackOnSeveralChannelsIsMergedRatherThanSplit() {
        let summary = syntheticSong(tracks: [sourceTrack(1, name: "Kit", channels: [1, 10])])
        var selection = SourceTrackSelection(summary)
        selection.send(1, to: .drums)

        let list = list(
            summary, drums: DrumSense(designation: .source(1), channel: 10), selection: selection)

        #expect(list.rows[0].badge == .drums)
        #expect(list.rows[0].detail.contains("merged onto that one device track"))
        #expect(!list.rows[0].detail.contains("Each channel becomes a device track of its own."))
    }

    @Test func atrackOnSeveralChannelsNamesThemAllAndSaysItSplits() {
        let list = list(
            syntheticSong(tracks: [sourceTrack(1, name: "Strings", channels: [2, 3])]))

        #expect(list.rows[0].channels == "ch 2, 3")
        #expect(list.rows[0].detail.contains("Each channel becomes a device track of its own."))
    }

    @Test func theconductorTrackIsBadgedRatherThanLeftLookingEmpty() {
        let list = list(
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
        let list = list(
            syntheticSong(tracks: [sourceTrack(1), sourceTrack(2), sourceTrack(3)]))

        #expect(list.header == "120 BPM · 4 beats to the bar · 3 source tracks")
    }

    @Test func awholeNumberedTempoLosesItsDecimal() {
        let straight = list(syntheticSong(tempoBPM: 120, tracks: [sourceTrack(1)]))
        let fractional = list(syntheticSong(tempoBPM: 92.5, tracks: [sourceTrack(1)]))

        #expect(straight.header.hasPrefix("120 BPM"))
        #expect(fractional.header.hasPrefix("92.5 BPM"))
    }

    @Test func onesourceTrackIsNotPluralised() {
        let list = list(syntheticSong(tracks: [sourceTrack(1)]))

        #expect(list.header.hasSuffix("1 source track"))
    }

    @Test func thepreFlightNoteCarriesWhatTheReadFound() {
        let collector = Collector()
        collector.add(.trackSplitByChannel, "source track(s) 1 carry more than one channel")
        let list = list(
            syntheticSong(
                tracks: [sourceTrack(1, channels: [1, 10])],
                diagnostics: collector.report()))

        #expect(list.note(verbose: false)?.contains("more than one channel") == true)
        #expect(list.note(verbose: true)?.contains("more than one channel") == true)
    }

    @Test func anuneventfulFileHasNoPreFlightNote() {
        let list = list(syntheticSong(tracks: [sourceTrack(1)]))

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
        let list = list(try summariseSong("test_file.mid"))

        #expect(!list.rows.isEmpty)
        #expect(list.rows.map(\.number) == Array(1...list.rows.count))
        #expect(list.rows.allSatisfy { !$0.name.isEmpty })
        #expect(list.rows.contains { !$0.isEmpty })
    }
}
