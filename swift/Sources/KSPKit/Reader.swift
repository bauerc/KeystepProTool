import Foundation

/// Decoding a flat `.KeyStepPro` dict into the object model. A port of `src/ksp/reader.py`.
///
/// The difficulty is in one place: within a single `(track, pattern, slot)` the trailing index is a
/// physical step for 48/49 but a note ordinal for 50/54 and 109-113 / 117-121. The device stores an
/// event list plus a separate per-step activity array, not a step grid, and reading it with a
/// single index space produces values that look almost right (spec section 4).
///
/// The two parameter sets are scanned by **different rules**, which is not a typo: melodic stops at
/// the first `127`, drum skips past it, because the drum array is a pool whose sentinel marks an
/// empty *entry* rather than the end of the list (spec section 4).
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
            // The factory Default.KeyStepPro omits it; user saves carry it. Worth surfacing
            // because M5 has to inject it when using the factory file as a template.
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

    /// Reassemble the project tempo from its three 7-bit chunks.
    ///
    /// Little-endian, holding BPM x 100. Verified against both saved projects: 96 + 93*128 = 12000
    /// -> 120.00, and 16 + 103*128 = 13200 -> 132.00. The final division is Python's true divide,
    /// so both operands cross to `Double` before it -- integer division here would floor every
    /// tempo that is not a whole BPM.
    private static func readTempo(_ raw: RawProject) throws -> Double {
        let lsb = try scalar(raw, Constants.itemProject, Constants.pTempoLSB, default: 0)
        let midsb = try scalar(raw, Constants.itemProject, Constants.pTempoMIDSB, default: 0)
        let msb = try scalar(raw, Constants.itemProject, Constants.pTempoMSB, default: 0)
        let hundredths =
            lsb + midsb * Constants.tempoChunk + msb * Constants.tempoChunk * Constants.tempoChunk
        return Double(hundredths) / Double(Constants.tempoScale)
    }

    /// Decode each scene's pattern chains from parameter 84.
    ///
    /// Chains are contiguous and sentinel-terminated: capture T5-chain-3 stores 0, 1, 2 and leaves
    /// the remaining 13 slots at 127. A value *after* a sentinel is not something the device
    /// produces, so it is reported rather than absorbed into the chain.
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

    /// Whether this track is in DRUM mode, from parameter 86 bit 6.
    ///
    /// Only Track 1 has a drum parameter set, so the bit is only meaningful there; MCC names the
    /// field "Arp/Drum mode state : bit 6", which on tracks 2-4 presumably means ARP. Reported as
    /// `false` for those rather than pretending it says something about drums.
    private static func readDrumMode(_ raw: RawProject, itemID: Int) throws -> Bool {
        guard itemID == Constants.drumTrackItemID else { return false }
        let bits = try scalar(raw, itemID, Constants.pTrackModeBits, default: 0)
        return bits & (1 << Constants.drumModeBit) != 0
    }

    /// Decode one pattern from whichever parameter set(s) hold notes.
    ///
    /// Track 1 carries a melodic and a drum set side by side and plays one or the other;
    /// `drumMode` is parameter 86 bit 6, not the 100 bitfield documented for it (spec section 5).
    /// Content alone is not decisive -- a pattern can hold real notes in both sets -- so the mode
    /// picks which the device plays while every note is still reported and the leftover set
    /// warned about.
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
            // Both sets hold notes, so the mode flag decides. The other set is leftovers from
            // before the track was switched over.
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

    /// Swing is stored with a +25 offset: 25 means 50%, i.e. no swing.
    ///
    /// MCC labels 97/114 a signed -25%..+25% offset; the device displays an absolute 50-75%, so
    /// the label is wrong and this reading is right.
    private static func swing(
        _ raw: RawProject, _ itemID: Int, _ param: Int, _ pattern: Int
    ) throws -> Int {
        try scalar(raw, itemID, param, pattern, default: Constants.swingOffset)
            + Constants.swingOffset
    }

    /// Decode every pool chunk of one pattern for one parameter set.
    ///
    /// The step-active flags are pattern-wide, so they are decoded once here and handed to each
    /// chunk rather than re-read per chunk or per note.
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

    /// Decode which steps the device will actually play, 0-based.
    ///
    /// Melodic (`48`) is one entry per step and lives wholly in chunk 1, so the result is a set of
    /// steps. Drum (`52`) is per lane, so the result is a set of `(lane, step)` pairs -- see
    /// ``Constants/drumStepActiveIndices(lane:step:)`` for the packing.
    private static func readStepActive(
        _ raw: RawProject, itemID: Int, pattern: Int, kind: NoteKind
    ) throws -> StepActive {
        if kind == .seq {
            // Chunk 1 is the whole array, not just where the flags happen to be: one entry per
            // step and at most 64 steps fills it exactly, so a pool spilling into chunks 2-3
            // leaves these behind (capture T4.6).
            let flags = try Keys.readArray(
                raw, itemID, Constants.pSeqStepActive, pattern, 1, length: Constants.maxSteps)
            return .steps(Set(flags.indices.filter { flags[$0] == 1 }))
        }

        // Read the flat array once and unpack, rather than locating each bit individually -- the
        // same 256 entries back every one of the 24 x 64 lane/step questions.
        var flat: [Int?] = []
        for chunk in 1...(Constants.slotsByItem[itemID] ?? 0) {
            flat += try Keys.readArray(
                raw, itemID, Constants.pDrumStepActive, pattern, chunk, length: Constants.maxSteps)
        }

        var pairs: Set<LaneStep> = []
        for (offset, stored) in flat.enumerated() {
            guard let value = stored, value != 0 else { continue }
            // Both operands are non-negative here, so floor and truncating division agree and the
            // plain operators are safe.
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
        // Melodic step skip is step-indexed; the drum equivalent is note-indexed. This asymmetry
        // is not a typo -- it is what the files consistently show. Being step-indexed, the melodic
        // array is one entry per step and so fills chunk 1 exactly, like 48: every sample file
        // holds 15 across chunk 1 and 0 across chunks 2-3. Reading it from the note's own chunk
        // would report a pattern's 65th note as playing on no pass at all.
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
                    // The drum array is a pool with holes, not a compacted list: deleting a note
                    // empties its entry and leaves the ones after it where they are. Skip the hole
                    // and keep scanning, or the rest of the pattern is silently discarded.
                    continue
                }
                // Melodic lists really are compacted, so the first sentinel ends the list and
                // anything past it is stale from an earlier edit.
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
                // Only reachable from a step outside 0-63, which no file we have holds. Guessing a
                // mask for it would put a note on the wrong passes silently.
                throw KSPError.value(
                    "note \(i + 1) of pattern \(pattern) slot \(slot) sits on step \(step + 1), "
                        + "past the \(Constants.maxSteps) steps the step-skip array covers")
            }
            let mask = skip[skipIndex] ?? 0
            // For drums the flags are per lane, so the note's own value selects the row; melodic
            // flags are a single per-step array.
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
            // The device has 24 lanes (MCC's Drum Map defines Note 1..Note 24), so a lane outside
            // 0-23 would mean parameter 117 is not the 0-based lane index we think it is. Worth
            // saying loudly rather than mapping it to some note anyway.
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

    /// Distinguish a genuinely empty slot from an uninitialised one.
    ///
    /// Track 1's slot 4 is zero-filled rather than sentinel-filled, so the `!= 127` existence rule
    /// alone decodes it as phantom notes (spec section 4). The test is deliberately narrow --
    /// note->step, pitch and velocity all uniformly zero -- because a real note list cannot look
    /// like that.
    public static func slotIsInitialised(
        noteStep: [Int?], pitch: [Int?], velocity: [Int?]
    ) -> Bool {
        !(noteStep.allSatisfy { $0 == 0 } && pitch.allSatisfy { $0 == 0 }
            && velocity.allSatisfy { $0 == 0 })
    }

    /// Cross-check the note list against the step-active flags.
    ///
    /// The device plays the flags, so a pooled note whose flag is clear is silent (spec section 4).
    /// Every flagged step having a pooled note is an invariant across all five samples, so a
    /// violation means the decode is wrong rather than the file being damaged.
    static func checkStepActive(
        pattern: Int, notes: [Note], active: StepActive, kind: NoteKind
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let site = Site(pattern: pattern, kind: kind.rawValue)

        // Drum flags are per lane, so compare (lane, step) pairs -- a union over lanes would hide
        // a flag whose lane holds nothing. Both branches sort: a Set has no order, and this list
        // goes straight into a message.
        let orphaned: [Int]
        switch active {
        case .steps(let steps):
            // Hoisted, as in the drum branch: inside the filter it would be rebuilt per step.
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

    /// Assert a note field is present.
    ///
    /// A note exists only because its note->step entry was populated, so every sibling parameter
    /// must be too. If one is missing the file is structurally unlike anything we have seen and
    /// guessing a value would be worse than stopping.
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

/// One drum lane at one step. The drum step-active flags are per lane, so the melodic set of steps
/// has no meaning here -- a union over lanes would hide a flag whose lane holds nothing.
public struct LaneStep: Sendable, Hashable {
    public let lane: Int
    public let step: Int

    public init(lane: Int, step: Int) {
        self.lane = lane
        self.step = step
    }
}

/// Which steps the device will actually play, 0-based.
///
/// Python returns one `frozenset` holding either bare steps or `(lane, step)` pairs depending on
/// the parameter set. Swift spells the two cases out instead of reaching for `AnyHashable`: every
/// call site already knows its ``NoteKind`` statically, so nothing is lost.
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
