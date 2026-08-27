import Foundation
import KSPKit
import KSPMIDI
import SwiftMIDIFile

/// What a MIDI file holds, said structurally: its source tracks and the counts a preview needs.
public struct SongSummary: Sendable, Hashable {
    public let sourceName: String
    public let tempoBPM: Double
    public let beatsPerBar: Double
    public let ticksPerBeat: Int
    /// Every track of the file, whether or not it holds notes.
    public let tracks: [SourceTrackSummary]

    public init(
        sourceName: String, tempoBPM: Double, beatsPerBar: Double, ticksPerBeat: Int,
        tracks: [SourceTrackSummary]
    ) {
        self.sourceName = sourceName
        self.tempoBPM = tempoBPM
        self.beatsPerBar = beatsPerBar
        self.ticksPerBeat = ticksPerBeat
        self.tracks = tracks
    }

    public var isEmpty: Bool { tracks.allSatisfy(\.isEmpty) }

    public init(_ midi: MusicalMIDI1File, sourceName: String) throws {
        // Default options, so no --midi-tracks selection can hide a track from the preview.
        let song = try MIDIImport.readSong(midi)
        // Guarded as `Song.stepsPerBar` is: a file may declare a bar of no beats, and a bar of no
        // ticks would divide by zero below.
        let ticksPerBar = max(1, Arithmetic.pyRound(Double(song.ticksPerBeat) * song.beatsPerBar))
        var clips: [Int: [Clip]] = [:]
        for clip in song.clips {
            guard let number = clip.sourceTracks.first else { continue }
            clips[number, default: []].append(clip)
        }
        self.init(
            sourceName: sourceName, tempoBPM: song.tempoBPM, beatsPerBar: song.beatsPerBar,
            ticksPerBeat: song.ticksPerBeat,
            tracks: midi.tracks.indices.map { index in
                SourceTrackSummary(
                    number: index + 1, name: trackName(midi.tracks[index]),
                    clips: clips[index + 1] ?? [], ticksPerBar: ticksPerBar)
            })
    }
}

public struct SourceTrackSummary: Sendable, Hashable {
    /// Counting from 1 over every track of the file, as `--midi-tracks` counts them.
    public let number: Int
    /// What the file calls this track, empty where it names none.
    public let name: String
    /// Counting from 1, as the import diagnostics word them. A track carrying several becomes
    /// one device track per channel.
    public let channels: [Int]
    public let noteCount: Int
    /// The bars the track fills from the start, rounded up, which is what the import lays out --
    /// not the distance between its first note and its last. None where it holds no note.
    public let bars: Int
    /// Every note on the percussion channel.
    public let isPercussion: Bool
    /// Any note on it, which is the one that says a drum track comes out of this: the import
    /// splits a track by channel, so a track holding percussion among other things still yields
    /// one. Reported here rather than left to the caller, which does not know a channel from a kit.
    public let holdsPercussion: Bool

    public init(
        number: Int, name: String, channels: [Int], noteCount: Int, bars: Int, isPercussion: Bool,
        holdsPercussion: Bool
    ) {
        self.number = number
        self.name = name
        self.channels = channels
        self.noteCount = noteCount
        self.bars = bars
        self.isPercussion = isPercussion
        self.holdsPercussion = holdsPercussion
    }

    public var isEmpty: Bool { noteCount == 0 }

    /// The clips one track of the file produced: one per channel, and none where it holds no note.
    init(number: Int, name: String, clips: [Clip], ticksPerBar: Int) {
        let notes = clips.flatMap(\.notes)
        let channels = Set(notes.map { $0.channel + 1 }).sorted()
        // The file's own length rather than the placement's: a preview says what was dropped, and
        // a track past the fourth is never placed at all.
        let furthest = notes.map { $0.tick + $0.durationTicks }.max() ?? 0
        let percussion = MIDIImport.drumChannel + 1
        self.init(
            number: number, name: name, channels: channels, noteCount: notes.count,
            bars: notes.isEmpty ? 0 : max(1, Arithmetic.ceilDiv(furthest, ticksPerBar)),
            isPercussion: channels == [percussion],
            holdsPercussion: channels.contains(percussion))
    }
}

/// `mido` hands the Python this for free; the Swift library leaves it in the event stream.
private func trackName(_ track: MusicalMIDI1File.Track) -> String {
    for event in track.events {
        if case .text(let text) = event.event, text.textType == .trackOrSequenceName {
            return text.text
        }
    }
    return ""
}
