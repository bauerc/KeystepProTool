import Foundation
import KSPKit
import KSPMIDI

/// What a project holds, said structurally: tracks, their patterns, and the counts a preview needs.
///
/// Composed entirely from ``KSPKit/Reader``'s model -- nothing here parses the format, and nothing
/// here renders text. That is what keeps it off the two CLIs' byte-for-byte contract: the app reads
/// this instead of running a command and parsing what it printed back.
public struct ProjectSummary: Sendable, Hashable {
    public let sourceName: String
    public let tempoBPM: Double
    public let globalSwingPercent: Int
    public let currentScene: Int
    /// All four, whether or not they hold anything.
    public let tracks: [TrackSummary]
    /// What the reader found on the way, for a caller that wants to show it before converting.
    public let diagnostics: Report

    public init(
        sourceName: String, tempoBPM: Double, globalSwingPercent: Int, currentScene: Int,
        tracks: [TrackSummary], diagnostics: Report = Report()
    ) {
        self.sourceName = sourceName
        self.tempoBPM = tempoBPM
        self.globalSwingPercent = globalSwingPercent
        self.currentScene = currentScene
        self.tracks = tracks
        self.diagnostics = diagnostics
    }

    public var isEmpty: Bool { tracks.allSatisfy(\.isEmpty) }

    /// Summarise an already-read project. The reader is the only thing that touches the file.
    public init(_ project: Project) {
        let chains = project.scenes.first { $0.number == project.currentScene }?.chains ?? []
        self.init(
            sourceName: project.sourceName, tempoBPM: project.tempoBPM,
            globalSwingPercent: project.globalSwingPercent, currentScene: project.currentScene,
            tracks: project.tracks.map { track in
                TrackSummary(
                    track, chain: chains.first { $0.track == track.number }?.patterns ?? [])
            },
            diagnostics: projectReport(project))
    }
}

/// Whether a track runs as a sequencer or as drums.
///
/// Two cases, not three: parameter 86 bit 6 is the Arp/Drum mode state, and on tracks 2-4 -- where
/// it presumably means ARP -- the reader reports it as `false` rather than guessing (spec 5). An
/// `arpeggiator` case would be a claim the format core does not make.
public enum TrackMode: String, Sendable, Hashable {
    case sequencer
    case drum
}

public struct TrackSummary: Sendable, Hashable {
    /// 1-4.
    public let number: Int
    /// What the exported `.mid` calls this track, so the preview and the file agree. The convention
    /// is ``KSPMIDI/Rendering/midiTrackName``'s.
    public let name: String
    public let mode: TrackMode
    /// The current Scene's Chain for this track, in play order. Empty when nothing is chained.
    public let chain: [Int]
    /// All sixteen pattern slots, whether or not they hold anything.
    public let patterns: [PatternSummary]

    public init(
        number: Int, name: String, mode: TrackMode, chain: [Int], patterns: [PatternSummary]
    ) {
        self.number = number
        self.name = name
        self.mode = mode
        self.chain = chain
        self.patterns = patterns
    }

    public var isEmpty: Bool { patterns.allSatisfy(\.isEmpty) }

    public init(_ track: Track, chain: [Int]) {
        // The set parameter 86 bit 6 selects is the one the device plays, and so the one every
        // count below is about -- the same choice `MIDIExport.renderProject` makes.
        let live: NoteKind = track.drumMode ? .drum : .seq
        self.init(
            number: track.number,
            name: track.drumMode ? "Track \(track.number) (drum)" : "Track \(track.number)",
            mode: track.drumMode ? .drum : .sequencer, chain: chain,
            patterns: track.patterns.map { PatternSummary($0, live: live, chain: chain) })
    }
}

public struct PatternSummary: Sendable, Hashable {
    /// 1-16.
    public let number: Int
    public let mode: PatternMode
    /// Everything in the Pool, both note sets.
    public let noteCount: Int
    /// How many of those the device plays: the live set's, minus the disabled ones. Below
    /// ``noteCount`` where a step is turned off, a note sits past the last step, or the other note
    /// set holds the rest.
    public let playableNoteCount: Int
    /// The live set's declared step count.
    public let stepCount: Int
    /// Parameter 40's latch, as read. Usually agrees with ``isEmpty``; where it does not, the
    /// reader has already said so.
    public let hasData: Bool
    /// The Chain this Pattern sits in, in play order, or empty when it is in none.
    public let chainedWith: [Int]

    public init(
        number: Int, mode: PatternMode, noteCount: Int, playableNoteCount: Int, stepCount: Int,
        hasData: Bool, chainedWith: [Int]
    ) {
        self.number = number
        self.mode = mode
        self.noteCount = noteCount
        self.playableNoteCount = playableNoteCount
        self.stepCount = stepCount
        self.hasData = hasData
        self.chainedWith = chainedWith
    }

    /// Holds nothing at all -- the question a greyed cell asks.
    public var isEmpty: Bool { noteCount == 0 }

    /// Something here would sound. Not the same as holding notes: a pattern of switched-off steps
    /// is not empty and still plays nothing.
    public var isEnabled: Bool { playableNoteCount > 0 }

    public init(_ pattern: Pattern, live: NoteKind, chain: [Int]) {
        let lastStep = MIDIExport.declaredStepCount(pattern, live)
        self.init(
            number: pattern.number, mode: pattern.mode, noteCount: pattern.notes.count,
            playableNoteCount: pattern.notes(of: live).count(where: {
                disablement($0, lastStep: lastStep) == nil
            }),
            stepCount: lastStep, hasData: pattern.hasData,
            chainedWith: chain.contains(pattern.number) ? chain : [])
    }
}
