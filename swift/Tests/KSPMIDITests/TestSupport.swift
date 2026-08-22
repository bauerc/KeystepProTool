import Foundation
import KSPKit
import SwiftMIDIFile
import Testing

@testable import KSPMIDI

/// A twin per target: SwiftPM cannot share a source file between two test targets.
enum RepoData {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent()  // KSPMIDITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // swift
        .deletingLastPathComponent()

    static let projectFiles = root.appending(path: "project_files")
}

enum Samples {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var projects: [String: Project] = [:]
    nonisolated(unsafe) private static var raws: [String: RawProject] = [:]

    static func raw(_ name: String) throws -> RawProject {
        lock.lock()
        defer { lock.unlock() }
        if let cached = raws[name] { return cached }
        let parsed = try LenientJSON.load(contentsOf: RepoData.projectFiles.appending(path: name))
        raws[name] = parsed
        return parsed
    }

    static func project(_ name: String) throws -> Project {
        lock.lock()
        defer { lock.unlock() }
        if let cached = projects[name] { return cached }
        let parsed = try Reader.load(
            contentsOf: RepoData.projectFiles.appending(path: "\(name).KeyStepPro"))
        projects[name] = parsed
        return parsed
    }
}

struct PlayedNote: Hashable {
    let start: Int
    let duration: Int
    let note: Int
    let velocity: Int
    let channel: Int
}

/// Re-derives lengths from the note-on/note-off pairs rather than the writer's own bookkeeping.
func played(_ midi: MusicalMIDI1File, _ trackName: String) throws -> [PlayedNote] {
    let track = try #require(midi.tracks.first { $0.name == trackName })
    var openNotes: [Pair: (start: Int, velocity: Int)] = [:]
    var notes: [PlayedNote] = []
    var tick = 0
    for event in track.events {
        tick += Int(event.delta.ticks(using: midi.timebase))
        switch event.event {
        case .noteOn(let on):
            let key = Pair(Int(on.channel), Int(on.note.number))
            #expect(openNotes[key] == nil, "\(key) retriggered before its note-off")
            openNotes[key] = (tick, Int(on.velocity.midi1Value))
        case .noteOff(let off):
            let key = Pair(Int(off.channel), Int(off.note.number))
            let open = try #require(openNotes[key])
            openNotes[key] = nil
            notes.append(
                PlayedNote(
                    start: open.start, duration: tick - open.start, note: Int(off.note.number),
                    velocity: open.velocity, channel: Int(off.channel)))
        default:
            break
        }
    }
    #expect(openNotes.isEmpty, "note(s) left hanging")
    return notes.stableSorted { ($0.start, $0.note) < ($1.start, $1.note) }
}

func markers(_ midi: MusicalMIDI1File) -> [(tick: Int, text: String)] {
    var found: [(tick: Int, text: String)] = []
    for track in midi.tracks {
        var tick = 0
        for event in track.events {
            tick += Int(event.delta.ticks(using: midi.timebase))
            if case .text(let text) = event.event, text.textType == .marker {
                found.append((tick, text.text))
            }
        }
    }
    return found
}

extension MusicalMIDI1File.Track {
    var name: String? {
        for event in events {
            if case .text(let text) = event.event, text.textType == .trackOrSequenceName {
                return text.text
            }
        }
        return nil
    }
}
