import Foundation

/// Decoding a flat `.KeyStepPro` dict into the object model. Within one `(track, pattern, slot)`
/// the trailing index is a step for 48/49 but a note ordinal for 50/54 and 109-113 / 117-121, and
/// a single index space decodes to values that look almost right (spec 4).
public enum Reader {
    /// Read and decode a `.KeyStepPro` file.
    public static func load(contentsOf url: URL) throws -> Project {
        try readProject(LenientJSON.load(contentsOf: url), sourceName: url.lastPathComponent)
    }

    /// Decode an already-parsed project dict.
    public static func readProject(_ raw: RawProject, sourceName: String = "") throws -> Project {
        let collector = Collector()

        guard case .string(let device)? = raw["device"] else {
            throw KSPError.value("not a KeyStepPro project: missing 'device'")
        }

        var version: String?
        switch raw["version"] {
        case nil:
            // The factory Default.KeyStepPro omits it; a converter has to inject it.
            collector.add(
                .noVersionKey, "no 'version' key (factory template rather than a saved project)")
        case .string(let stored):
            version = stored
        case .some(let other):
            throw KSPError.value("'version' holds \(other.typeName), expected str")
        }

        let tracks = try Constants.trackItemIDs.enumerated().map {
            try readTrack(raw, number: $0.offset + 1, itemID: $0.element)
        }

        return Project(
            device: device,
            version: version,
            tempoBPM: try readTempo(raw),
            globalSwingPercent: try scalar(
                raw, Constants.itemProject, Constants.pGlobalSwing, default: 50),
            currentScene: try scalar(
                raw, Constants.itemProject, Constants.pCurrentScene, default: 0) + 1,
            tracks: tracks,
            scenes: try readScenes(raw, collector),
            sourceName: sourceName,
            diagnostics: collector.report())
    }

    private static func scalar(
        _ raw: RawProject, _ item: Int, _ param: Int, _ indices: Int..., default fallback: Int
    ) throws -> Int {
        try Keys.getInt(raw, item, param, indices: indices) ?? fallback
    }

    /// Reassemble the tempo from its three little-endian 7-bit chunks, holding BPM x 100. Both
    /// operands cross to `Double` first: integer division would floor every fractional BPM.
    private static func readTempo(_ raw: RawProject) throws -> Double {
        let lsb = try scalar(raw, Constants.itemProject, Constants.pTempoLSB, default: 0)
        let midsb = try scalar(raw, Constants.itemProject, Constants.pTempoMIDSB, default: 0)
        let msb = try scalar(raw, Constants.itemProject, Constants.pTempoMSB, default: 0)
        let hundredths =
            lsb + midsb * Constants.tempoChunk + msb * Constants.tempoChunk * Constants.tempoChunk
        return Double(hundredths) / Double(Constants.tempoScale)
    }

    /// Decode each scene's pattern chains from parameter 84. Chains are contiguous and
    /// sentinel-terminated; a value after a sentinel is reported, never absorbed into the chain.
    private static func readScenes(_ raw: RawProject, _ collector: Collector) throws -> [Scene] {
        try (1...Constants.sceneCount).map { scene in
            var chains: [Chain] = []
            for track in 1...Constants.sceneTrackCount {
                let stored = try (1...Constants.chainSlots).map { slot in
                    try Keys.getInt(
                        raw, Constants.itemScenes, Constants.pSceneChain, scene, track, slot)
                }
                var patterns: [Int] = []
                for value in stored {
                    guard let value, value != Constants.sentinel else { break }
                    // Stored 0-based, reported the way the device numbers patterns.
                    patterns.append(value + 1)
                }
                if stored[patterns.count...].contains(where: {
                    $0 != nil && $0 != Constants.sentinel
                }
                ) {
                    collector.add(
                        .chainHasHole,
                        "track \(track)'s chain has a gap after \(patterns.count) pattern(s); "
                            + "everything after it was ignored",
                        site: Site(scene: scene))
                }
                if !patterns.isEmpty {
                    chains.append(Chain(track: track, patterns: patterns))
                }
            }
            return Scene(number: scene, chains: chains)
        }
    }

    private static func readTrack(_ raw: RawProject, number: Int, itemID: Int) throws -> Track {
        let drumMode = try readDrumMode(raw, itemID: itemID)
        let patterns = try (1...Constants.patternsPerTrack).map {
            try readPattern(raw, itemID: itemID, pattern: $0, drumMode: drumMode)
        }
        return Track(number: number, itemID: itemID, patterns: patterns, drumMode: drumMode)
    }

    /// Whether this track is in DRUM mode, from parameter 86 bit 6. Only track 1 has a drum set,
    /// so tracks 2-4 read `false` rather than reporting what the bit means there.
    private static func readDrumMode(_ raw: RawProject, itemID: Int) throws -> Bool {
        guard itemID == Constants.drumTrackItemID else { return false }
        let bits = try scalar(raw, itemID, Constants.pTrackModeBits, default: 0)
        return bits & (1 << Constants.drumModeBit) != 0
    }

    /// Decode one pattern from whichever parameter set(s) hold notes. Content is not decisive --
    /// both sets can hold real notes -- so `drumMode` picks which plays and both are reported.
    private static func readPattern(
        _ raw: RawProject, itemID: Int, pattern: Int, drumMode: Bool
    ) throws -> Pattern {
        let collector = Collector()
        let site = Site(pattern: pattern)
        let isDrumTrack = itemID == Constants.drumTrackItemID

        let (seqNotes, seqDiagnostics) = try readNoteLists(
            raw, itemID: itemID, pattern: pattern, kind: .seq)
        var drumNotes: [Note] = []
        var drumDiagnostics: [Diagnostic] = []
        if isDrumTrack {
            (drumNotes, drumDiagnostics) = try readNoteLists(
                raw, itemID: itemID, pattern: pattern, kind: .drum)
        }

        let notes = seqNotes + drumNotes
        collector.extend(seqDiagnostics)
        collector.extend(drumDiagnostics)

        let mode: PatternMode
        if !seqNotes.isEmpty && !drumNotes.isEmpty {
            // Both sets hold notes, so the mode flag decides; the other set is leftovers.
            mode = drumMode ? .drum : .seq
            let melodic = "melodic (\(seqNotes.count))"
            let drum = "drum (\(drumNotes.count))"
            let (stale, live) = drumMode ? (melodic, drum) : (drum, melodic)
            collector.add(
                .mixedNoteSets,
                "holds both melodic (\(seqNotes.count)) and drum (\(drumNotes.count)) notes; "
                    + "parameter 86 bit 6 says \(live) plays and \(stale) is stale. "
                    + "Both are reported",
                site: site)
        } else if !drumNotes.isEmpty {
            mode = .drum
            if !drumMode {
                collector.add(
                    .drumModeFlagDisagrees, "holds drum notes but parameter 86 bit 6 is clear",
                    site: site)
            }
        } else if !seqNotes.isEmpty {
            mode = .seq
            if drumMode {
                collector.add(
                    .drumModeFlagDisagrees,
                    "holds only melodic notes but parameter 86 bit 6 says the track is in "
                        + "drum mode", site: site)
            }
        } else {
            mode = .empty
        }

        let hasData =
            try scalar(raw, itemID, Constants.pPatternDataState, pattern, default: 0)
            == Constants.patternHasData
        if !notes.isEmpty && !hasData {
            collector.add(
                .hasDataFlagDisagrees,
                "holds \(notes.count) notes but parameter 40 says it has no data", site: site)
        }

        let scale = try scalar(raw, itemID, Constants.pScale, pattern, default: 0)
        if Constants.scaleName(scale) == nil {
            collector.add(
                .scaleOffList,
                "parameter 108 holds \(scale), past the end of the device's scale list", site: site)
        }

        return Pattern(
            number: pattern,
            mode: mode,
            hasData: hasData,
            seqStepCount: try stepCount(raw, itemID, Constants.pSeqStepCount, pattern),
            seqSwingPercent: try swing(raw, itemID, Constants.pSeqSwing, pattern),
            seqBits: try patternBits(
                raw, itemID, Constants.pSeqPatternBits, pattern, collector, site),
            drumStepCount: isDrumTrack
                ? try stepCount(raw, itemID, Constants.pDrumStepCount, pattern) : nil,
            drumSwingPercent: isDrumTrack
                ? try swing(raw, itemID, Constants.pDrumSwing, pattern) : nil,
            drumBits: isDrumTrack
                ? try patternBits(
                    raw, itemID, Constants.pDrumPatternBits, pattern, collector, site, kind: "drum")
                : nil,
            rootNote: try scalar(raw, itemID, Constants.pRootNote, pattern, default: 0),
            scale: scale,
            notes: notes,
            diagnostics: collector.report())
    }

    /// Decode 99 or 116 -- step size, triplet, polyrhythm and direction.
    ///
    /// Both fields share a layout (spec 3.3, protocol tier 5), so the only thing the caller varies
    /// is which parameter to read.
    private static func patternBits(
        _ raw: RawProject, _ itemID: Int, _ param: Int, _ pattern: Int, _ collector: Collector,
        _ site: Site, kind: String = "seq"
    ) throws -> PatternBits {
        let bits = PatternBits.decode(try scalar(raw, itemID, param, pattern, default: 0))
        if bits.unallocated != 0 {
            collector.add(
                .patternBitsUnknown,
                "parameter \(param) holds \(bits.raw) (\(binary(bits.raw, width: 9))), whose bit "
                    + "\(binary(bits.unallocated)) no capture accounted for",
                site: Site(
                    track: site.track, pattern: site.pattern, kind: kind, slot: site.slot,
                    scene: site.scene))
        }
        return bits
    }

    /// Step counts are stored 0-based: 15 means a 16-step pattern.
    private static func stepCount(
        _ raw: RawProject, _ itemID: Int, _ param: Int, _ pattern: Int
    ) throws -> Int {
        try scalar(raw, itemID, param, pattern, default: 0) + Constants.stepCountOffset
    }

    /// Swing is stored with a +25 offset: 25 means 50%, i.e. no swing. MCC's signed -25..+25
    /// label for 97/114 is wrong; the device displays an absolute 50-75%.
    private static func swing(
        _ raw: RawProject, _ itemID: Int, _ param: Int, _ pattern: Int
    ) throws -> Int {
        try scalar(raw, itemID, param, pattern, default: Constants.swingOffset)
            + Constants.swingOffset
    }

    /// Decode every pool chunk of one pattern for one parameter set. The step-active flags are
    /// pattern-wide, so they are decoded once and handed to each chunk.
    private static func readNoteLists(
        _ raw: RawProject, itemID: Int, pattern: Int, kind: NoteKind
    ) throws -> ([Note], [Diagnostic]) {
        let active = try readStepActive(raw, itemID: itemID, pattern: pattern, kind: kind)

        var notes: [Note] = []
        var diagnostics: [Diagnostic] = []
        for slot in 1...(Constants.slotsByItem[itemID] ?? 0) {
            let (slotNotes, slotDiagnostics) = try readSlot(
                raw, itemID: itemID, pattern: pattern, slot: slot, kind: kind, active: active)
            notes += slotNotes
            diagnostics += slotDiagnostics
        }

        diagnostics += checkStepActive(
            pattern: pattern, notes: notes, active: active, kind: kind)
        return (notes, diagnostics)
    }

    /// Which steps the device will actually play, 0-based: melodic (`48`) yields steps, drum
    /// (`52`) yields `(lane, step)` pairs.
    private static func readStepActive(
        _ raw: RawProject, itemID: Int, pattern: Int, kind: NoteKind
    ) throws -> StepActive {
        if kind == .seq {
            // Chunk 1 is the whole array: one entry per step fills all 64, so a pool spilling
            // into chunks 2-3 leaves these behind.
            let flags = try Keys.readArray(
                raw, itemID, Constants.pSeqStepActive, pattern, 1, length: Constants.maxSteps)
            return .steps(Set(flags.indices.filter { flags[$0] == 1 }))
        }

        // Unpack the flat array once: the same 256 entries answer all 24 x 64 lane/step questions.
        var flat: [Int?] = []
        for chunk in 1...(Constants.slotsByItem[itemID] ?? 0) {
            flat += try Keys.readArray(
                raw, itemID, Constants.pDrumStepActive, pattern, chunk, length: Constants.maxSteps)
        }

        var pairs: Set<LaneStep> = []
        for (offset, stored) in flat.enumerated() {
            guard let value = stored, value != 0 else { continue }
            // Non-negative operands, so floor and truncating division agree.
            let lane = offset / Constants.drumStepActivePartsPerLane
            let part = offset % Constants.drumStepActivePartsPerLane
            guard lane < Constants.drumLaneCount else { continue }
            let base = part * Constants.drumStepActiveBitsPerEntry
            for bit in 0..<Constants.drumStepActiveBitsPerEntry {
                let step = base + bit
                if step < Constants.maxSteps, value >> bit & 1 == 1 {
                    pairs.insert(LaneStep(lane: lane, step: step))
                }
            }
        }
        return .lanes(pairs)
    }

    private static func readSlot(
        _ raw: RawProject, itemID: Int, pattern: Int, slot: Int, kind: NoteKind, active: StepActive
    ) throws -> ([Note], [Diagnostic]) {
        let drum = kind == .drum
        let pStep = drum ? Constants.pDrumNoteStep : Constants.pSeqNoteStep
        let pPitch = drum ? Constants.pDrumPitch : Constants.pSeqPitch
        let pGate = drum ? Constants.pDrumGate : Constants.pSeqGate
        let pVelocity = drum ? Constants.pDrumVelocity : Constants.pSeqVelocity
        let pShift = drum ? Constants.pDrumTimeShift : Constants.pSeqTimeShift
        let pRandom = drum ? Constants.pDrumRandomness : Constants.pSeqRandomness

        func column(_ param: Int) throws -> [Int?] {
            try Keys.readArray(raw, itemID, param, pattern, slot, length: Constants.maxSteps)
        }

        let noteStep = try column(pStep)
        guard noteStep[0] != nil else { return ([], []) }  // parameter set absent for this item

        let pitch = try column(pPitch)
        let velocity = try column(pVelocity)
        guard slotIsInitialised(noteStep: noteStep, pitch: pitch, velocity: velocity) else {
            return ([], [])
        }

        let gate = try column(pGate)
        let shift = try column(pShift)
        let random = try column(pRandom)
        // Melodic step skip (49) is step-indexed and lives in chunk 1; the drum 53 is
        // note-indexed. The asymmetry is not a typo.
        let skip =
            drum
            ? try column(Constants.pDrumStepSkip)
            : try Keys.readArray(
                raw, itemID, Constants.pSeqStepSkip, pattern, 1, length: Constants.maxSteps)

        var notes: [Note] = []
        var diagnostics: [Diagnostic] = []
        for (i, stored) in noteStep.enumerated() {
            guard let step = stored else { break }  // ran off the end of the stored array
            if step == Constants.sentinel {
                if drum {
                    // The drum array is a pool with holes: a sentinel is an emptied entry, not
                    // the end of the list, so scanning must continue past it.
                    continue
                }
                // Melodic lists are compacted, so the first sentinel ends the list.
                let trailing = noteStep[(i + 1)...].filter { $0 != nil && $0 != Constants.sentinel }
                if !trailing.isEmpty {
                    diagnostics.append(
                        Diagnostic(
                            code: .trailingPoolValues,
                            detail:
                                "\(trailing.count) value(s) after the end of the note list "
                                + "were ignored",
                            site: Site(pattern: pattern, slot: slot), subjects: trailing.count))
                }
                break
            }

            let value = try required(pitch[i])
            let skipIndex = drum ? i : step
            guard skip.indices.contains(skipIndex) else {
                // Only reachable from a step outside 0-63; guessing a mask would silently move it.
                throw KSPError.value(
                    "note \(i + 1) of pattern \(pattern) slot \(slot) sits on step \(step + 1), "
                        + "past the \(Constants.maxSteps) steps the step-skip array covers")
            }
            let mask = skip[skipIndex] ?? 0
            notes.append(
                Note(
                    kind: kind,
                    slot: slot,
                    index: i + 1,
                    step: step + 1,
                    pitch: value,
                    velocity: try required(velocity[i]),
                    gateRaw: try required(gate[i]),
                    gate: Constants.decodeGate(try required(gate[i])),
                    timeShift: try required(shift[i]) - Constants.timeShiftCentre,
                    randomness: try required(random[i]),
                    skip: Constants.decodeSkipMask(mask),
                    active: active.contains(lane: value, step: step)))
        }

        if drum {
            // A lane outside 0-23 would mean 117 is not the 0-based lane index we take it for.
            let outOfRange = Set(
                notes.map(\.pitch).filter { $0 >= Constants.drumLaneCount }
            ).sorted()
            if !outOfRange.isEmpty {
                diagnostics.append(
                    Diagnostic(
                        code: .drumLaneOutOfRange,
                        detail:
                            "drum lane(s) \(outOfRange) are outside "
                            + "0-\(Constants.drumLaneCount - 1)",
                        site: Site(pattern: pattern, slot: slot), subjects: outOfRange.count))
            }
        }
        return (notes, diagnostics)
    }

    /// Track 1's slot 4 is zero-filled rather than sentinel-filled, so the `!= 127` existence
    /// rule alone decodes it as phantom notes (spec 4).
    public static func slotIsInitialised(
        noteStep: [Int?], pitch: [Int?], velocity: [Int?]
    ) -> Bool {
        !(noteStep.allSatisfy { $0 == 0 } && pitch.allSatisfy { $0 == 0 }
            && velocity.allSatisfy { $0 == 0 })
    }

    /// Cross-check the note list against the step-active flags: the device plays the flags, so a
    /// pooled note whose flag is clear is silent (spec 4).
    static func checkStepActive(
        pattern: Int, notes: [Note], active: StepActive, kind: NoteKind
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let site = Site(pattern: pattern, kind: kind.rawValue)

        // Drum flags are per lane, so compare (lane, step) pairs; a union over lanes would hide a
        // flag whose lane holds nothing. Both branches sort, since the message shows the list.
        let orphaned: [Int]
        switch active {
        case .steps(let steps):
            let heldSteps = Set(notes.map(\.step))
            orphaned = steps.map { $0 + 1 }.filter { !heldSteps.contains($0) }.sorted()
        case .lanes(let lanes):
            let held = Set(notes.map { LaneStep(lane: $0.pitch, step: $0.step) })
            orphaned = Set(
                lanes.filter { !held.contains(LaneStep(lane: $0.lane, step: $0.step + 1)) }
                    .map { $0.step + 1 }
            ).sorted()
        }
        if !orphaned.isEmpty {
            diagnostics.append(
                Diagnostic(
                    code: .flagWithoutNote,
                    detail:
                        "step(s) \(orphaned) are flagged active but hold no note. Every flagged "
                        + "step should have a pooled note, so this means the note pool was "
                        + "decoded wrongly rather than that the file is damaged",
                    site: site, subjects: orphaned.count))
        }

        let silent = notes.filter { !$0.active }
        if !silent.isEmpty {
            let steps = Set(silent.map(\.step)).sorted()
            diagnostics.append(
                Diagnostic(
                    code: .disabledStepOff,
                    detail:
                        "\(silent.count) disabled note(s), step turned off, so they do not play "
                        + "on the device (step(s) \(steps))",
                    site: site, subjects: silent.count))
        }
        return diagnostics
    }

    /// Assert a note field is present: a populated note->step entry implies every sibling.
    private static func required(_ value: Int?) throws -> Int {
        guard let value else {
            throw KSPError.value("note parameter missing where the note list says a note exists")
        }
        return value
    }

    /// Python's `format(value, '#0<width>b')`: a `0b` prefix, zero-padded to `width` including it.
    private static func binary(_ value: Int, width: Int = 0) -> String {
        let digits = String(value, radix: 2)
        return "0b" + String(repeating: "0", count: max(0, width - 2 - digits.count)) + digits
    }
}

/// One drum lane at one step; the drum step-active flags are per lane, not per step.
public struct LaneStep: Sendable, Hashable {
    public let lane: Int
    public let step: Int

    public init(lane: Int, step: Int) {
        self.lane = lane
        self.step = step
    }
}

/// Which steps the device will actually play, 0-based: bare steps for melodic, pairs for drum.
enum StepActive {
    case steps(Set<Int>)
    case lanes(Set<LaneStep>)

    /// Whether the flag for this note is set. `step` is 0-based, as stored.
    func contains(lane: Int, step: Int) -> Bool {
        switch self {
        case .steps(let steps): steps.contains(step)
        case .lanes(let lanes): lanes.contains(LaneStep(lane: lane, step: step))
        }
    }
}
