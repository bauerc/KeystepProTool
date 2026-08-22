import Foundation
import KSPKit
import KSPMIDI

/// What a project holds, said structurally: tracks, their patterns, and the counts a preview needs.
public struct ProjectSummary: Sendable, Hashable {
    public let sourceName: String
    public let tempoBPM: Double
    public let globalSwingPercent: Int
    public let currentScene: Int
    /// All four, whether or not they hold anything.
    public let tracks: [TrackSummary]
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

    public init(_ project: Project) {
        // Only the current Scene's Chains: another Scene says nothing about how this one will play.
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

/// Two cases, not the glossary's three: parameter 86 bit 6 is the Arp/Drum mode state, and an
/// `arpeggiator` case would be a claim the format core does not make.
public enum TrackMode: String, Sendable, Hashable {
    case sequencer
    case drum
}

public struct TrackSummary: Sendable, Hashable {
    /// 1-4.
    public let number: Int
    /// What the exported `.mid` calls this track, so the preview and the file agree.
    public let name: String
    public let mode: TrackMode
    /// All sixteen pattern slots, whether or not they hold anything.
    public let patterns: [PatternSummary]

    public init(number: Int, name: String, mode: TrackMode, patterns: [PatternSummary]) {
        self.number = number
        self.name = name
        self.mode = mode
        self.patterns = patterns
    }

    public var isEmpty: Bool { patterns.allSatisfy(\.isEmpty) }

    /// This track's Chain in the current Scene, in play order, or empty when nothing is chained.
    public var chain: [Int] { patterns.first { !$0.chain.isEmpty }?.chain ?? [] }

    public init(_ track: Track, chain: [Int]) {
        // Parameter 86 bit 6 decides both the track's name and which note set the counts are about.
        let live: NoteKind = track.drumMode ? .drum : .seq
        self.init(
            number: track.number, name: Rendering.trackName(track.number, kind: live),
            mode: track.drumMode ? .drum : .sequencer,
            patterns: track.patterns.map { PatternSummary($0, live: live, chain: chain) })
    }
}

public struct PatternSummary: Sendable, Hashable {
    /// 1-16.
    public let number: Int
    /// The set this Pattern plays; where it holds both, parameter 86 bit 6 has already decided.
    public let mode: PatternMode
    /// Everything in the Pool -- notes and triggers, live set and leftovers alike.
    public let noteCount: Int
    /// Enabled is not audible: this counts only the two reasons the device gives you a switch for
    /// -- a step turned off, and a note past the last step.
    public let enabledNoteCount: Int
    /// The live set's declared step count.
    public let stepCount: Int
    /// Parameter 40's latch, as read. Usually agrees with ``isEmpty``, but need not.
    public let hasData: Bool
    /// The whole Chain this Pattern plays in, in play order, or empty when it is in none.
    public let chain: [Int]

    public init(
        number: Int, mode: PatternMode, noteCount: Int, enabledNoteCount: Int, stepCount: Int,
        hasData: Bool, chain: [Int]
    ) {
        self.number = number
        self.mode = mode
        self.noteCount = noteCount
        self.enabledNoteCount = enabledNoteCount
        self.stepCount = stepCount
        self.hasData = hasData
        self.chain = chain
    }

    public var isEmpty: Bool { noteCount == 0 }

    /// Not the same as holding notes: a pattern of switched-off steps is not empty and plays none.
    public var isEnabled: Bool { enabledNoteCount > 0 }

    public init(_ pattern: Pattern, live: NoteKind, chain: [Int]) {
        let lastStep = MIDIExport.declaredStepCount(pattern, live)
        self.init(
            number: pattern.number, mode: pattern.mode, noteCount: pattern.notes.count,
            enabledNoteCount: pattern.notes(of: live).count(where: {
                disablement($0, lastStep: lastStep) == nil
            }),
            stepCount: lastStep, hasData: pattern.hasData,
            chain: chain.contains(pattern.number) ? chain : [])
    }
}
