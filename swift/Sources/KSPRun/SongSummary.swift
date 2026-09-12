import Foundation
import KSPKit
import KSPMIDI
import SwiftMIDIFile

public struct SongSummary: Sendable, Hashable {
    public let sourceName: String
    public let tempoBPM: Double
    public let beatsPerBar: Double
    public let ticksPerBeat: Int
    public let tracks: [SourceTrackSummary]
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
        let song = try MIDIImport.readSong(midi)
        let ticksPerBar = max(
            1, Arithmetic.roundHalfToEven(Double(song.ticksPerBeat) * song.beatsPerBar))
        var clips: [Int: [Clip]] = [:]
        for clip in song.clips {
            guard let number = clip.sourceTracks.first else { continue }
            clips[number, default: []].append(clip)
        }
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
    public let name: String
    /// Counting from 1, as the import diagnostics word them.
    public let channels: [Int]
    public let noteCount: Int
    public let bars: Int
    public let isPercussion: Bool
    public let isDrumTrack: Bool
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

    init(
        number: Int, name: String, clips: [Clip], ticksPerBar: Int, isDrumTrack: Bool,
        carriesTiming: Bool
    ) {
        var channels: Set<Int> = []
        var noteCount = 0
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

private func carriesTiming(_ track: MusicalMIDI1File.Track) -> Bool {
    track.events.contains {
        switch $0.event {
        case .tempo, .timeSignature: return true
        default: return false
        }
    }
}

private func trackName(_ track: MusicalMIDI1File.Track) -> String {
    for event in track.events {
        if case .text(let text) = event.event, text.textType == .trackOrSequenceName {
            return text.text
        }
    }
    return ""
}
