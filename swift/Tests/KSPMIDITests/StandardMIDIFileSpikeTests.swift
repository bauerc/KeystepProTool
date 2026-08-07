import Foundation
import SwiftMIDIFile
import Testing

@testable import KSPMIDI

// M8's spike. swift-midi-file is not a mido drop-in -- a track holds `Event` values carrying a
// `MusicalMIDIFileDeltaTime` enum rather than mido's integer ticks, and note on/off are separate
// cases as in the file format itself. This proves the dependency resolves, links, and can express
// what M12 needs before any porting work depends on it.

/// A quarter-note ascending run, the shape `render_pattern` produces for one bar of 1/4 steps.
private let spikeNotes: [UInt7] = [60, 62, 64, 65]

private func fourNoteFile() -> MusicalMIDI1File {
    var track = MusicalMIDI1File.Track()
    for note in spikeNotes {
        track.events.append(.noteOn(note: note, velocity: .midi1(100)))
        track.events.append(.noteOff(delta: .noteQuarter, note: note, velocity: .midi1(0)))
    }
    return MusicalMIDI1File(
        format: .multipleTracksSynchronous,
        timebase: .init(ticksPerQuarterNote: KSPMIDI.defaultTicksPerQuarterNote),
        tracks: [track]
    )
}

@Test func fourNoteFileSurvivesAWriteAndReadBack() throws {
    let written = try fourNoteFile().rawData()
    let read = try MusicalMIDI1File(data: written)

    #expect(read.timebase.ticksPerQuarterNote == KSPMIDI.defaultTicksPerQuarterNote)
    #expect(read.tracks.count == 1)

    let notes = try #require(read.tracks.first).events.compactMap { event -> UInt7? in
        guard case .noteOn(let payload) = event.event else { return nil }
        return payload.note.number
    }
    #expect(notes == spikeNotes)
}

@Test func deltaTimesRoundTripAsTicks() throws {
    let written = try fourNoteFile().rawData()
    let read = try MusicalMIDI1File(data: written)
    let track = try #require(read.tracks.first)

    // Every note-off sits one quarter note after its note-on. Reading back gives ticks, not the
    // symbolic case that was written, so the comparison has to go through the timebase.
    let deltas = track.events.map { $0.delta.ticks(using: read.timebase) }
    #expect(deltas == [0, 480, 0, 480, 0, 480, 0, 480])
}
