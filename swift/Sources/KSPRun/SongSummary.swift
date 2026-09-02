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
    /// What the file will cost the import, said before anything is written.
    public let diagnostics: Report

    public init(
        sourceName: String, tempoBPM: Double, beatsPerBar: Double, ticksPerBeat: Int,
        tracks: [SourceTrackSummary], diagnostics: Report = Report()
    ) {
        self.sourceName = sourceName
        self.tempoBPM = tempoBPM
        self.beatsPerBar = beatsPerBar
        self.ticksPerBeat = ticksPerBeat
        self.tracks = tracks
        self.diagnostics = diagnostics
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
        // `apply`'s own `drumSource`, read the same way off the same clips, so the preview cannot
        // name a drum track the import would not. A clip is one channel of one track, which is why
        // a track carrying channel 10 among others still gives up its channel 10 part to this.
        // It takes no options, so `--drum-channel` cannot move this search or the badge below.
        let drumSource = song.clips.first {
            $0.isPercussion(on: MIDIImport.drumChannel)
        }?.sourceTracks.first
        let tracks = midi.tracks.indices.map { index in
            SourceTrackSummary(
                number: index + 1, name: trackName(midi.tracks[index]),
                clips: clips[index + 1] ?? [], ticksPerBar: ticksPerBar,
                isDrumTrack: index + 1 == drumSource,
                carriesTiming: carriesTiming(midi.tracks[index]))
        }
        self.init(
            sourceName: sourceName, tempoBPM: song.tempoBPM, beatsPerBar: song.beatsPerBar,
            ticksPerBeat: song.ticksPerBeat, tracks: tracks, diagnostics: splitReport(tracks))
    }
}

/// A track carrying several channels is imported as a device track per channel, which is a
/// surprise worth saying before the conversion runs rather than after. Worded as `convert` words
/// it, in the tense of something that has not happened yet.
private func splitReport(_ tracks: [SourceTrackSummary]) -> Report {
    let collector = Collector()
    let split = tracks.filter { $0.channels.count > 1 }
    if !split.isEmpty {
        collector.add(
            .trackSplitByChannel,
            "source track(s) \(split.map { String($0.number) }.joined(separator: ", ")) carry more "
                + "than one channel; each channel becomes a device track of its own, the first "
                + "percussion channel the drum track and the rest melodic",
            subjects: split.reduce(0) { $0 + $1.channels.count })
    }
    return collector.report()
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
    /// Notes on the percussion channel, which the import reads as drums without being asked.
    /// Not a promise of a drum track: the device has one, so a second percussion track is
    /// imported melodically, and `--drum-track` names a track of its own regardless.
    public let isPercussion: Bool
    /// The one the import would take for the drum track, left to `--drum-track` to override.
    public let isDrumTrack: Bool
    /// Carries the file's tempo and time signature but no notes, so the import reads nothing from
    /// it. A track holding both is music, not bookkeeping, which is every track of a type 0 file.
    public let isConductor: Bool

    public init(
        number: Int, name: String, channels: [Int], noteCount: Int, bars: Int, isPercussion: Bool,
        isDrumTrack: Bool = false, isConductor: Bool = false
    ) {
        self.number = number
        self.name = name
        self.channels = channels
        self.noteCount = noteCount
        self.bars = bars
        self.isPercussion = isPercussion
        self.isDrumTrack = isDrumTrack
        self.isConductor = isConductor
    }

    public var isEmpty: Bool { noteCount == 0 }

    /// The clips one track of the file produced: one per channel, and none where it holds no note.
    init(
        number: Int, name: String, clips: [Clip], ticksPerBar: Int, isDrumTrack: Bool,
        carriesTiming: Bool
    ) {
        var channels: Set<Int> = []
        var noteCount = 0
        // The file's own length rather than the placement's: a preview says what was dropped, and
        // a track past the fourth is never placed at all.
        var furthest = 0
        for clip in clips {
            for note in clip.notes {
                channels.insert(note.channel + 1)
                noteCount += 1
                furthest = max(furthest, note.tick + note.durationTicks)
            }
        }
        self.init(
            number: number, name: name, channels: channels.sorted(), noteCount: noteCount,
            bars: noteCount == 0 ? 0 : max(1, Arithmetic.ceilDiv(furthest, ticksPerBar)),
            isPercussion: channels.contains(MIDIImport.drumChannel + 1),
            isDrumTrack: isDrumTrack, isConductor: carriesTiming && noteCount == 0)
    }
}

/// The events that make a track the file's timing rather than one of its parts.
private func carriesTiming(_ track: MusicalMIDI1File.Track) -> Bool {
    track.events.contains {
        switch $0.event {
        case .tempo, .timeSignature: return true
        default: return false
        }
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
