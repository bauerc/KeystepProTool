/// Which parameter set a note came from: a seq pitch is a MIDI note, a drum pitch is a lane.
public enum NoteKind: String, Sendable, Hashable, CaseIterable {
    case seq
    case drum
}

/// ``both`` is not a hardware mode: the file holds notes in both sets and neither is decidable.
public enum PatternMode: String, Sendable, Hashable {
    case seq
    case drum
    case both
    case empty
}

public enum PlaybackDirection: String, Sendable, Hashable {
    case forward
    case random
    case walk
    case unknown
}

public struct PatternBits: Sendable, Hashable {
    public let raw: Int

    public let stepDenominator: Int

    public let triplet: Bool
    public let polyrhythm: Bool
    public let direction: PlaybackDirection

    public let unallocated: Int

    public static func decode(_ raw: Int) -> PatternBits {
        let directions: [Int: PlaybackDirection] = [
            Constants.directionForward: .forward,
            Constants.directionRandom: .random,
            Constants.directionWalk: .walk,
        ]
        return PatternBits(
            raw: raw,
            stepDenominator: Constants.stepDenominator(raw),
            triplet: Constants.isTriplet(raw),
            polyrhythm: Constants.isPolyrhythm(raw),
            direction: directions[Constants.directionIndex(raw)] ?? .unknown,
            unallocated: Constants.unallocatedBits(raw))
    }

    public var stepsPerBeat: Int { stepDenominator / 4 }

    public var label: String { "1/\(stepDenominator)\(triplet ? "T" : "")" }

    public func toJSON() -> JSONNode {
        .object([
            ("raw", .int(raw)),
            ("step_size", .string(label)),
            ("step_denominator", .int(stepDenominator)),
            ("triplet", .bool(triplet)),
            ("polyrhythm", .bool(polyrhythm)),
            ("direction", .string(direction.rawValue)),
            ("unallocated", .int(unallocated)),
        ])
    }
}

/// ``step`` is 1-based here; the file stores it 0-based.
public struct Note: Sendable, Hashable {
    public let kind: NoteKind
    public let slot: Int

    public let index: Int

    public let step: Int

    public let pitch: Int

    public let velocity: Int
    public let gateRaw: Int

    public let gate: Double?

    public let timeShift: Int

    public let randomness: Int

    public let skip: [Int]

    /// The step-active bit in 48/52: a note exists in the pool whether or not it is set.
    public let active: Bool

    public init(
        kind: NoteKind, slot: Int, index: Int, step: Int, pitch: Int, velocity: Int, gateRaw: Int,
        gate: Double?, timeShift: Int, randomness: Int, skip: [Int], active: Bool = true
    ) {
        self.kind = kind
        self.slot = slot
        self.index = index
        self.step = step
        self.pitch = pitch
        self.velocity = velocity
        self.gateRaw = gateRaw
        self.gate = gate
        self.timeShift = timeShift
        self.randomness = randomness
        self.skip = skip
        self.active = active
    }

    public var label: String { labelled(nil) }

    public func labelled(_ drumMap: DrumMap?) -> String {
        guard kind == .drum else { return "\(Constants.noteName(pitch)) (\(pitch))" }
        guard let drumMap else { return "lane \(pitch)" }
        return drumMap.labelForLane(pitch)
    }

    public func toJSON(drumMap: DrumMap? = nil) -> JSONNode {
        var members: [(String, JSONNode)] = [
            ("kind", .string(kind.rawValue)),
            ("slot", .int(slot)),
            ("index", .int(index)),
            ("step", .int(step)),
            ("pitch", .int(pitch)),
            ("velocity", .int(velocity)),
            ("gate_raw", .int(gateRaw)),
            ("gate", gate.map { JSONNode.double($0) } ?? .null),
            ("time_shift", .int(timeShift)),
            ("randomness", .int(randomness)),
            ("skip", .array(skip.map { .int($0) })),
            ("active", .bool(active)),
        ]
        if let drumMap, kind == .drum, drumMap.hasLane(pitch) {
            let note = drumMap.notes[pitch]
            members.append(("drum_note", .int(note)))
            members.append(("drum_note_name", .string(Constants.noteName(note))))
        }
        return .object(members)
    }
}

public struct Pattern: Sendable, Hashable {
    public let number: Int
    public let mode: PatternMode

    public let hasData: Bool

    public let seqStepCount: Int
    public let seqSwingPercent: Int
    public let seqBits: PatternBits
    public let drumStepCount: Int?
    public let drumSwingPercent: Int?
    public let drumBits: PatternBits?

    public let rootNote: Int

    public let scale: Int

    public let notes: [Note]

    public let diagnostics: Report

    public init(
        number: Int, mode: PatternMode, hasData: Bool, seqStepCount: Int, seqSwingPercent: Int,
        seqBits: PatternBits, drumStepCount: Int?, drumSwingPercent: Int?, drumBits: PatternBits?,
        rootNote: Int, scale: Int, notes: [Note], diagnostics: Report = Report()
    ) {
        self.number = number
        self.mode = mode
        self.hasData = hasData
        self.seqStepCount = seqStepCount
        self.seqSwingPercent = seqSwingPercent
        self.seqBits = seqBits
        self.drumStepCount = drumStepCount
        self.drumSwingPercent = drumSwingPercent
        self.drumBits = drumBits
        self.rootNote = rootNote
        self.scale = scale
        self.notes = notes
        self.diagnostics = diagnostics
    }

    public var warnings: [String] { diagnostics.messages }

    public var isEmpty: Bool { notes.isEmpty }

    public var scaleName: String? { Constants.scaleName(scale) }

    public func notes(of kind: NoteKind) -> [Note] {
        notes.filter { $0.kind == kind }
    }

    public func bits(_ kind: NoteKind) -> PatternBits {
        kind == .drum ? drumBits ?? seqBits : seqBits
    }

    func with(notes: [Note]) -> Pattern {
        Pattern(
            number: number, mode: mode, hasData: hasData, seqStepCount: seqStepCount,
            seqSwingPercent: seqSwingPercent, seqBits: seqBits, drumStepCount: drumStepCount,
            drumSwingPercent: drumSwingPercent, drumBits: drumBits, rootNote: rootNote,
            scale: scale, notes: notes, diagnostics: diagnostics)
    }

    public func toJSON(drumMap: DrumMap? = nil) -> JSONNode {
        .object([
            ("pattern", .int(number)),
            ("mode", .string(mode.rawValue)),
            ("has_data", .bool(hasData)),
            ("seq_step_count", .int(seqStepCount)),
            ("seq_swing_percent", .int(seqSwingPercent)),
            ("seq_bits", seqBits.toJSON()),
            ("drum_step_count", drumStepCount.map { JSONNode.int($0) } ?? .null),
            ("drum_swing_percent", drumSwingPercent.map { JSONNode.int($0) } ?? .null),
            ("drum_bits", drumBits?.toJSON() ?? .null),
            ("root_note", .int(rootNote)),
            ("scale", .int(scale)),
            ("scale_name", scaleName.map { JSONNode.string($0) } ?? .null),
            ("notes", .array(notes.map { $0.toJSON(drumMap: drumMap) })),
            ("warnings", .array(warnings.map { .string($0) })),
            ("diagnostics", diagnostics.toJSON()),
        ])
    }
}

public struct Track: Sendable, Hashable {
    public let number: Int
    public let itemID: Int
    public let patterns: [Pattern]

    public let drumMode: Bool

    public init(number: Int, itemID: Int, patterns: [Pattern], drumMode: Bool = false) {
        self.number = number
        self.itemID = itemID
        self.patterns = patterns
        self.drumMode = drumMode
    }

    public var isEmpty: Bool { patterns.allSatisfy(\.isEmpty) }

    public func pattern(_ number: Int) -> Pattern { patterns[number - 1] }

    func keeping(_ numbers: Set<Int>) -> Track {
        Track(
            number: number, itemID: itemID,
            patterns: patterns.filter { numbers.contains($0.number) }, drumMode: drumMode)
    }

    public func toJSON(drumMap: DrumMap? = nil) -> JSONNode {
        .object([
            ("track", .int(number)),
            ("item_id", .int(itemID)),
            ("drum_mode", .bool(drumMode)),
            ("patterns", .array(patterns.map { $0.toJSON(drumMap: drumMap) })),
        ])
    }
}

/// ``patterns`` is 1-based and in chain order; the file stores it 0-based.
public struct Chain: Sendable, Hashable {
    public let track: Int
    public let patterns: [Int]

    public init(track: Int, patterns: [Int]) {
        self.track = track
        self.patterns = patterns
    }

    public func toJSON() -> JSONNode {
        .object([("track", .int(track)), ("patterns", .array(patterns.map { .int($0) }))])
    }
}

public struct Scene: Sendable, Hashable {
    public let number: Int
    public let chains: [Chain]

    public init(number: Int, chains: [Chain] = []) {
        self.number = number
        self.chains = chains
    }

    public var isEmpty: Bool { chains.isEmpty }

    public func toJSON() -> JSONNode {
        .object([("scene", .int(number)), ("chains", .array(chains.map { $0.toJSON() }))])
    }
}

public struct Project: Sendable, Hashable {
    public let device: String

    public let version: String?

    public let tempoBPM: Double
    public let globalSwingPercent: Int
    public let currentScene: Int
    public let tracks: [Track]
    public let scenes: [Scene]
    public let sourceName: String
    public let diagnostics: Report

    public init(
        device: String, version: String?, tempoBPM: Double, globalSwingPercent: Int,
        currentScene: Int, tracks: [Track], scenes: [Scene] = [], sourceName: String = "",
        diagnostics: Report = Report()
    ) {
        self.device = device
        self.version = version
        self.tempoBPM = tempoBPM
        self.globalSwingPercent = globalSwingPercent
        self.currentScene = currentScene
        self.tracks = tracks
        self.scenes = scenes
        self.sourceName = sourceName
        self.diagnostics = diagnostics
    }

    public var warnings: [String] { diagnostics.messages }

    public var chainedScenes: [Scene] { scenes.filter { !$0.isEmpty } }

    public func track(_ number: Int) -> Track { tracks[number - 1] }

    public func select(tracks: Set<Int> = [], patterns: Set<Int> = []) -> Project {
        var narrowed = self.tracks.filter { tracks.isEmpty || tracks.contains($0.number) }
        if !patterns.isEmpty {
            narrowed = narrowed.map { $0.keeping(patterns) }
        }
        return replacing(tracks: narrowed)
    }

    public func select(cells: [Int: Set<Int>]) -> Project {
        guard !cells.isEmpty else { return self }
        return replacing(
            tracks: tracks.compactMap { track in
                cells[track.number].map { track.keeping($0) }
            })
    }

    private func replacing(tracks: [Track]) -> Project {
        Project(
            device: device, version: version, tempoBPM: tempoBPM,
            globalSwingPercent: globalSwingPercent, currentScene: currentScene, tracks: tracks,
            scenes: scenes, sourceName: sourceName, diagnostics: diagnostics)
    }

    public func toJSON(drumMap: DrumMap? = nil) -> JSONNode {
        var members: [(String, JSONNode)] = [
            ("source", .string(sourceName)),
            ("device", .string(device)),
            ("version", version.map { JSONNode.string($0) } ?? .null),
            ("tempo_bpm", .double(tempoBPM)),
            ("global_swing_percent", .int(globalSwingPercent)),
            ("current_scene", .int(currentScene)),
            ("scenes", .array(chainedScenes.map { $0.toJSON() })),
            ("warnings", .array(warnings.map { .string($0) })),
            ("diagnostics", diagnostics.toJSON()),
        ]
        if let drumMap {
            members.append(("drum_map", drumMap.toJSON()))
        }
        members.append(("tracks", .array(tracks.map { $0.toJSON(drumMap: drumMap) })))
        return .object(members)
    }
}
