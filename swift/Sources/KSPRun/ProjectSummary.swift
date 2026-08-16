import Foundation
import KSPKit
import KSPMIDI

/// What a project holds, said structurally: tracks, their patterns, and the counts a preview needs.
///
/// Composed from ``KSPKit/Reader``'s model. Nothing here parses the format and nothing here renders
/// text, which is what keeps a preview off the two CLIs' byte-for-byte contract.
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
        // Only the current Scene's Chains: a Scene the device is not on says nothing about how what
        // you are looking at will play.
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
/// Two cases, not the glossary's three: parameter 86 bit 6 is the Arp/Drum mode state, and on
/// tracks 2-4 -- where it presumably means ARP -- the reader reports it as `false` rather than
/// guessing (spec 5). An `arpeggiator` case would be a claim the format core does not make.
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
    /// Derived rather than stored, so it cannot disagree with the Patterns that make it up.
    public var chain: [Int] { patterns.first { !$0.chain.isEmpty }?.chain ?? [] }

    public init(_ track: Track, chain: [Int]) {
        // Parameter 86 bit 6 decides both what this track is called and which note set every count
        // below is about -- the same choice `MIDIExport.renderProject` makes.
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
    /// The set this Pattern plays. Where it holds both, parameter 86 bit 6 has already decided
    /// which one this is, and the reader reports the leftovers as a finding rather than in here.
    public let mode: PatternMode
    /// Everything in the Pool -- notes and triggers, live set and leftovers alike. Where this runs
    /// well ahead of ``enabledNoteCount``, ``ProjectSummary/diagnostics`` says why; a preview
    /// showing what will sound wants the smaller number.
    public let noteCount: Int
    /// How many of those the user has left switched on: the live set's, minus the ones on a step
    /// that is off and the ones past the last step.
    ///
    /// Enabled is not audible. The spec lists six reasons a note might not play (4); this counts
    /// the two the device gives you a switch for, and the two `--include-disabled` exports.
    public let enabledNoteCount: Int
    /// The live set's declared step count.
    public let stepCount: Int
    /// Parameter 40's latch, as read. Usually agrees with ``isEmpty``; where it does not, the
    /// reader has already said so.
    public let hasData: Bool
    /// The Chain this Pattern plays in, in play order, or empty when it is in none. It carries the
    /// whole Chain rather than the rest of it, so a cell can draw where it sits in the run.
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

    /// Holds nothing at all -- the question a greyed cell asks.
    public var isEmpty: Bool { noteCount == 0 }

    /// Something here is switched on. Not the same as holding notes: a pattern of switched-off
    /// steps is not empty and still plays nothing.
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
