/// The decoded object model: project -> tracks -> patterns -> notes. A port of `src/ksp/model.py`.
///
/// This is what the flat key/value file becomes once both index spaces have been resolved.
/// Everything here is plain data with no reference back to the raw dict, so consumers never need
/// to know the key grammar.
///
/// Every type is a value type, which the Python gets from `@dataclass(frozen=True)` and Swift gets
/// from `struct`. The `toJSON()` methods are ports of the Python `to_dict`s and carry their key
/// order: the dump's `--json` is a contract the two ports share.

/// Which parameter set a note was decoded from.
///
/// Track 1 carries a melodic and a drum set side by side, and they mean different things: a
/// melodic note's value is a MIDI pitch, a drum note's is a lane index. Tagging each note is what
/// lets a pattern hold both without the two becoming indistinguishable.
public enum NoteKind: String, Sendable, Hashable, CaseIterable {
    case seq
    case drum
}

/// Which parameter set(s) of a pattern hold notes.
///
/// ``both`` is not a hardware mode -- the device plays one or the other. It means the file has
/// notes in both sets and we cannot yet tell which is live, so the reader reports everything
/// rather than guessing.
public enum PatternMode: String, Sendable, Hashable {
    case seq
    case drum
    case both
    case empty
}

/// How a pattern walks its steps (99 / 116 bits 5-6).
///
/// ``unknown`` is the honest reading of the fourth value: two bits allow it but the device never
/// produced it during T5.5, so nothing knows its name.
public enum PlaybackDirection: String, Sendable, Hashable {
    case forward
    case random
    case walk
    case unknown
}

/// One decoded 99 / 116 field.
///
/// The sequencer and drum fields share this layout; only their defaults differ (spec 3.3). ``raw``
/// is kept so a caller can see the value the decode came from without going back to the file.
public struct PatternBits: Sendable, Hashable {
    public let raw: Int

    /// 4, 8, 16 or 32 -- the step size as the device displays it.
    public let stepDenominator: Int

    public let triplet: Bool
    public let polyrhythm: Bool
    public let direction: PlaybackDirection

    /// Bits set that tier 5 never accounted for. Always 0 in every known file.
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

    /// How the device writes it: `1/16`, or `1/16T` for a triplet.
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

/// One entry from a slot's note list.
///
/// ``step`` is 1-based here, matching how the hardware and the project descriptions count beats,
/// though the file stores it 0-based.
public struct Note: Sendable, Hashable {
    public let kind: NoteKind
    public let slot: Int

    /// Ordinal position in the note list, 1-based. This is the file's own note index -- distinct
    /// from ``step``, which is where it plays.
    public let index: Int

    public let step: Int

    /// MIDI pitch for a ``NoteKind/seq`` note; 0-based drum lane for a ``NoteKind/drum`` note
    /// (lane 0 is the kick, confirmed against project_5).
    public let pitch: Int

    public let velocity: Int
    public let gateRaw: Int

    /// Gate length in steps. The ladder covers all of 0-127, so this is `nil` only for a
    /// ``gateRaw`` outside that range, i.e. a corrupt file. See ``Constants/gateTable``.
    public let gate: Double?

    /// Signed, already offset from the stored centre of 49.
    public let timeShift: Int

    public let randomness: Int

    /// Which of the 16/32/48/64 sequences this note plays in.
    public let skip: [Int]

    /// Whether the step-active flag says the device plays this note.
    ///
    /// Existence and audibility are different tests: a note is in the pool because `50`/`54` is
    /// not the sentinel, but it only sounds if its bit in `48`/`52` is set. Capture D1 toggled a
    /// drum step off without deleting the note -- the pool entry survived unchanged and the step
    /// did not sound. Defaults to `true` so a caller constructing a note by hand gets an audible
    /// one.
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

    /// Human-readable pitch: a note name, or a bare drum lane number.
    public var label: String { labelled(nil) }

    /// Like ``label``, but resolving a drum lane through `drumMap`.
    ///
    /// Without a map a drum note can only be reported as `lane 0`, because which MIDI note that
    /// lane transmits is a device setting the file does not contain.
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

/// One of a track's 16 patterns.
///
/// The melodic and drum parameter sets each carry their own step count and swing, so both are
/// reported rather than collapsing them into one pair of numbers that would silently belong to
/// whichever set happened to win. The `drum*` fields are `nil` on tracks 2-4, which have no drum
/// set at all.
public struct Pattern: Sendable, Hashable {
    public let number: Int
    public let mode: PatternMode

    /// From parameter 40, the firmware's own "this pattern holds data" flag.
    public let hasData: Bool

    public let seqStepCount: Int
    public let seqSwingPercent: Int
    public let seqBits: PatternBits
    public let drumStepCount: Int?
    public let drumSwingPercent: Int?
    public let drumBits: PatternBits?

    /// Pitch class 0-11 (parameter 107). The octave the display shows is not stored anywhere in
    /// the file.
    public let rootNote: Int

    /// Index into ``Constants/scaleNames`` (parameter 108). One list serves both parameter sets --
    /// there is no drum twin.
    public let scale: Int

    public let notes: [Note]

    /// Inconsistencies found while decoding. Reported, never silently fixed -- a reader that
    /// quietly repairs its input hides exactly the surprises this milestone exists to find.
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

    /// Every diagnostic in full, for callers that just want the text.
    public var warnings: [String] { diagnostics.messages }

    public var isEmpty: Bool { notes.isEmpty }

    public var scaleName: String? { Constants.scaleName(scale) }

    public func notes(of kind: NoteKind) -> [Note] {
        notes.filter { $0.kind == kind }
    }

    /// The 99 / 116 field governing `kind`, falling back to the melodic one on the tracks that
    /// have no drum set.
    public func bits(_ kind: NoteKind) -> PatternBits {
        kind == .drum ? drumBits ?? seqBits : seqBits
    }

    /// A copy holding `notes` instead. Used by ``Project/select(track:pattern:)``.
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

/// One of the four sequencer tracks.
public struct Track: Sendable, Hashable {
    public let number: Int
    public let itemID: Int
    public let patterns: [Pattern]

    /// Whether the track's Arp/Drum mode bit (parameter 86, bit 6) is set.
    ///
    /// Only Track 1 has a drum parameter set, and this is what says whether it is the live one. It
    /// is track-level rather than per-pattern, matching the device's Drum button. Parameter 100
    /// was expected to carry this and does not -- it reads 26 everywhere.
    public let drumMode: Bool

    public init(number: Int, itemID: Int, patterns: [Pattern], drumMode: Bool = false) {
        self.number = number
        self.itemID = itemID
        self.patterns = patterns
        self.drumMode = drumMode
    }

    public var isEmpty: Bool { patterns.allSatisfy(\.isEmpty) }

    /// Pattern `number`, counting from 1.
    public func pattern(_ number: Int) -> Pattern { patterns[number - 1] }

    /// A copy holding only the patterns `numbers` names.
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

/// One track's pattern chain within a scene (parameter 84).
///
/// ``patterns`` is in chain order and 1-based, matching how the device numbers patterns; the file
/// stores them 0-based.
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

/// One of the 16 scenes, holding a chain per track.
///
/// Only tracks that actually chain appear: an unused slot reads the sentinel across all 16
/// entries, which is every scene of every sample project.
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

/// A decoded `.KeyStepPro` project.
public struct Project: Sendable, Hashable {
    public let device: String

    /// Absent in the factory `Default.KeyStepPro`, present in user saves.
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

    /// Track `number`, counting from 1.
    public func track(_ number: Int) -> Track { tracks[number - 1] }

    /// A copy narrowed to `tracks` and `patterns`, empty meaning all.
    ///
    /// The project's own order survives, since a set has none.
    public func select(tracks: Set<Int> = [], patterns: Set<Int> = []) -> Project {
        var narrowed = self.tracks.filter { tracks.isEmpty || tracks.contains($0.number) }
        if !patterns.isEmpty {
            narrowed = narrowed.map { $0.keeping(patterns) }
        }
        return replacing(tracks: narrowed)
    }

    /// A copy narrowed to `cells`, the patterns to keep per track number, empty meaning all.
    ///
    /// Keeps a different set on each track, which the cross product above cannot express. A track
    /// `cells` does not name is dropped.
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
            // Named at the top level because every resolved drum note below depends on it, and it
            // is an assumption about the user's device rather than anything read from the file.
            members.append(("drum_map", drumMap.toJSON()))
        }
        members.append(("tracks", .array(tracks.map { $0.toJSON(drumMap: drumMap) })))
        return .object(members)
    }
}
