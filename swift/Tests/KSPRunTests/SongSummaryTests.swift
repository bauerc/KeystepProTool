import Foundation
import KSPMIDI
import SwiftMIDIFile
import Testing

@testable import KSPRun

private let ticksPerBeat = 480

/// One type 0 track carrying several channels, which is the shape no file in the repository has.
private func mixedTrackFile(
    _ events: [(tick: Int, pitch: Int, channel: Int)], name: String, length: Int = 120
) -> MusicalMIDI1File {
    var track = MusicalMIDI1File.Track()
    track.events.append(.text(type: .trackOrSequenceName, string: name))
    let timed =
        events
        .flatMap {
            [
                (tick: $0.tick, on: 1, pitch: $0.pitch, channel: $0.channel),
                (tick: $0.tick + length, on: 0, pitch: $0.pitch, channel: $0.channel),
            ]
        }
        // note_off sorts before note_on at the same tick, or a retrigger reads as a hanging note.
        .sorted { ($0.tick, $0.on, $0.pitch) < ($1.tick, $1.on, $1.pitch) }
    var previous = 0
    for event in timed {
        let delta = MusicalMIDIFileDeltaTime.ticks(UInt32(event.tick - previous))
        let note = UInt7(event.pitch)
        let channel = UInt4(event.channel)
        track.events.append(
            event.on == 1
                ? .noteOn(delta: delta, note: note, velocity: .midi1(100), channel: channel)
                : .noteOff(delta: delta, note: note, velocity: .midi1(64), channel: channel))
        previous = event.tick
    }
    return MusicalMIDI1File(
        format: .singleTrack, timebase: .init(ticksPerQuarterNote: UInt16(ticksPerBeat)),
        tracks: [track])
}

/// The counts are the ones the reading layer yields, cross-checked against the files themselves.
@Suite struct SongSummaryTests {
    static func summarise(_ name: String) throws -> SongSummary {
        let result = SummaryRunner.song(
            SummaryRunner.Options(path: RepoData.projectFiles.appending(path: name)))
        #expect(result.message == nil)
        return try #require(result.summary)
    }

    @Test func itReportsEveryTrackOfTheFileIncludingTheOnesHoldingNoNotes() throws {
        let summary = try Self.summarise("m6-test-file.mid")
        #expect(summary.tracks.count == 6)
        #expect(summary.tracks.map(\.number) == Array(1...6))
        #expect(summary.tracks[0].isEmpty)
        #expect(summary.tracks[1].isEmpty)
        #expect(summary.tracks.map(\.noteCount) == [0, 0, 64, 160, 3, 64])
        #expect(!summary.isEmpty)
    }

    @Test func itCarriesTheSongHeader() throws {
        let summary = try Self.summarise("m6-test-file.mid")
        #expect(summary.sourceName == "m6-test-file.mid")
        #expect(summary.tempoBPM == 120.0)
        #expect(summary.beatsPerBar == 4.0)
        #expect(summary.ticksPerBeat == 480)
    }

    @Test func itNamesATrackAsTheFileNamesIt() throws {
        let summary = try Self.summarise("m6-test-file.mid")
        // The first track carries the tempo and no name; the second is named and holds nothing.
        #expect(summary.tracks[0].name == "")
        #expect(summary.tracks[1].name == "Inst 1")
        #expect(try Self.summarise("test_file_simple.mid").tracks[0].name == "Deluxe Classic")
    }

    @Test func itCountsChannelsFromOne() throws {
        // Channel 3 of `test_file_simple.mid` is the raw 2 its notes carry.
        #expect(try Self.summarise("test_file_simple.mid").tracks[0].channels == [3])
        #expect(try Self.summarise("m6-test-file.mid").tracks[2].channels == [1])
        #expect(try Self.summarise("m6-test-file.mid").tracks[0].channels == [])
    }

    @Test func itMeasuresATrackInWholeBars() throws {
        let summary = try Self.summarise("m6-test-file.mid")
        // Track 6's furthest note ends at tick 15240, which is 7.9 bars of 1920.
        #expect(summary.tracks.map(\.bars) == [0, 0, 4, 3, 2, 8])
        #expect(try Self.summarise("test_file_simple.mid").tracks[0].bars == 2)
    }

    @Test func itMarksAPercussionTrack() throws {
        // Built rather than read: no MIDI file the repository tracks holds percussion.
        let midi = mixedTrackFile([(0, 36, 9), (1920, 38, 9)], name: "Kit")
        let drums = try SongSummary(midi, sourceName: "kit.mid").tracks[0]
        #expect(drums.channels == [10])
        #expect(drums.isPercussion)
        #expect(drums.holdsPercussion)
        #expect(drums.noteCount == 2)
        #expect(drums.bars == 2)

        let melodic = try Self.summarise("test_file.mid").tracks[0]
        #expect(!melodic.isPercussion)
        #expect(!melodic.holdsPercussion)
        #expect(melodic.noteCount == 26)
    }

    @Test func itKeepsAMultiChannelTrackAsOneRow() throws {
        let midi = mixedTrackFile(
            [(0, 60, 0), (480, 62, 0), (960, 64, 0), (0, 36, 9), (1920, 38, 9)], name: "Mixed")
        // Import splits that one track into a clip -- and so a device track -- per channel.
        #expect(try MIDIImport.readSong(midi).clips.count == 2)

        let track = try SongSummary(midi, sourceName: "mixed.mid").tracks[0]
        #expect(track.name == "Mixed")
        #expect(track.channels == [1, 10])
        #expect(track.noteCount == 5)
        #expect(track.bars == 2)
        // Not a drum track, but one comes out of it: the channel 10 half becomes one.
        #expect(!track.isPercussion)
        #expect(track.holdsPercussion)
    }

    @Test func itSurvivesAFileDeclaringABarOfNoBeats() throws {
        var midi = mixedTrackFile([(0, 60, 0)], name: "Odd")
        var track = midi.tracks[0]
        track.events.insert(.timeSignature(numerator: 0, denominator: 2), at: 1)
        midi.tracks[0] = track

        // A bar of one tick, as `Song.stepsPerBar` clamps such a file to a bar of one step: the
        // count is nonsense either way, but the preview reports it rather than trapping.
        #expect(try SongSummary(midi, sourceName: "odd.mid").tracks[0].bars == 120)
    }

    @Test func itReportsAnUnreadableFileInsteadOfAnEmptySummary() {
        let result = SummaryRunner.song(
            SummaryRunner.Options(
                path: RepoData.projectFiles.appending(path: "project_5.KeyStepPro")))
        #expect(result.summary == nil)
        #expect(result.message != nil)
    }
}
