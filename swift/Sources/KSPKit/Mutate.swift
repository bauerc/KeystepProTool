/// Targeted edits to a parsed `.KeyStepPro` project -- a port of `src/ksp/mutate.py`.
///
/// Every operation here is specified by a hardware capture diff rather than inferred. Placing one
/// melodic note costs **8 keys, not one** -- six note-indexed parameters, the step-indexed
/// step-active flag in slot 1, and the pattern's data-state latch -- and the table with its fresh
/// values is in spec section 4. Step skip (`49`) is deliberately not written: an empty project
/// already holds 15, "plays on all four sequences", everywhere.
///
/// Every function returns a new dictionary and never adds or removes a key. The key set is fixed
/// (spec section 2), so an address the file does not already carry is an error rather than
/// something to create.
///
/// ``noteUpdates`` and ``drumNoteUpdates`` are the delta forms, letting a bulk writer apply
/// placements to one working dictionary instead of copying the whole key set per note. This lives
/// in `KSPKit` rather than `KSPMIDI` because `mutate.py` imports no MIDI library: it is `ksp/`
/// minus MIDI, and keeping it here is what puts it on CI's Linux runner.
public enum Mutate {
    /// Pool chunks a melodic note may occupy. Track 1's fourth chunk is a zero-filled phantom the
    /// firmware never uses (capture D2-chord4-tr1), so the real ceiling is 3 everywhere.
    static let slots = Constants.poolSlots

    static let noteParams = [
        Constants.pSeqNoteStep, Constants.pSeqPitch, Constants.pSeqGate, Constants.pSeqVelocity,
        Constants.pSeqTimeShift, Constants.pSeqRandomness,
    ]

    /// The drum set, in the same order, so one recipe serves both (spec 3.2). `117` holds a lane
    /// index where `109` holds a pitch -- the one field that means something different.
    static let drumNoteParams = [
        Constants.pDrumNoteStep, Constants.pDrumPitch, Constants.pDrumGate,
        Constants.pDrumVelocity, Constants.pDrumTimeShift, Constants.pDrumRandomness,
    ]

    // MARK: - Guards

    static func checkPattern(_ pattern: Int) throws {
        guard 1...Constants.patternsPerTrack ~= pattern else {
            throw KSPError.value(
                "pattern \(pattern) out of range 1-\(Constants.patternsPerTrack)")
        }
    }

    static func checkSlot(_ item: Int, _ slot: Int) throws {
        if item == Constants.drumTrackItemID && slot > slots {
            throw KSPError.value(
                "item \(item) slot \(slot) is a zero-filled phantom the firmware never writes "
                    + "(spec section 4); a fourth chord voice goes to slot 1 like any other note")
        }
        guard 1...slots ~= slot else {
            throw KSPError.value("slot \(slot) out of range 1-\(slots)")
        }
    }

    static func checkValue(_ name: String, _ value: Int) throws {
        guard 0...Constants.sentinel ~= value else {
            throw KSPError.value("\(name) \(value) out of range 0-\(Constants.sentinel)")
        }
    }

    /// Narrower than the 7-bit field: the encoder cannot reach past these.
    static func checkTimeShift(_ stored: Int) throws {
        let low = Constants.timeShiftStoredMin
        let high = Constants.timeShiftStoredMax
        guard low...high ~= stored else {
            let displayed = stored - Constants.timeShiftCentre
            throw KSPError.value(
                "time shift \(stored) (displayed \(signed(displayed))) out of range "
                    + "\(low)-\(high) (displayed \(signed(Constants.timeShiftRange.min)).."
                    + "\(signed(Constants.timeShiftRange.max)))")
        }
    }

    /// Python's `f"{value:+d}"`, which always writes a sign.
    private static func signed(_ value: Int) -> String {
        value < 0 ? "\(value)" : "+\(value)"
    }

    // MARK: - Writing

    /// Copy `raw` with `updates` applied, refusing any key it does not hold.
    ///
    /// The refusal is the point: the key set is fixed, so a key that is not already there means the
    /// address was computed wrongly.
    static func withValues(_ raw: RawProject, _ updates: [String: Int]) throws -> RawProject {
        let missing = updates.keys.filter { raw[$0] == nil }
        if !missing.isEmpty {
            throw KSPError.key("not in the file: \(missing.sorted().joined(separator: ", "))")
        }
        var result = raw
        for (name, value) in updates {
            result[name] = .int(value)
        }
        return result
    }

    /// Apply `updates` to `raw` in place, refusing any key it does not hold.
    ///
    /// The one exception to this type's copy-on-write rule, and the reason the `*Updates`
    /// functions exist: a converter placing hundreds of notes owns its working dictionary and
    /// cannot afford a copy of 153,495 keys per note.
    public static func mergeUpdates(_ raw: inout RawProject, _ updates: [String: Int]) throws {
        let missing = updates.keys.filter { raw[$0] == nil }
        if !missing.isEmpty {
            throw KSPError.key("not in the file: \(missing.sorted().joined(separator: ", "))")
        }
        for (name, value) in updates {
            raw[name] = .int(value)
        }
    }

    // MARK: - Reading the pool

    /// The 0-based step of each pool entry in one slot, stopping at the end of the live prefix.
    ///
    /// Throws if a sentinel is followed by a live entry. The melodic pool is compacted -- verified
    /// across every sample file (spec section 4) -- so a hole means this pool is not shaped the way
    /// every measurement says it should be, and appending to it is not something any capture covers.
    static func slotSteps(_ raw: RawProject, _ item: Int, _ pattern: Int, _ slot: Int) throws
        -> [Int]
    {
        let entries = (0..<Constants.maxSteps).map { index -> Int? in
            guard
                case .int(let value)? = raw[
                    Keys.key(item, Constants.pSeqNoteStep, pattern, slot, index + 1)]
            else { return nil }
            return value == Constants.sentinel ? nil : value
        }
        let live = entries.compactMap { $0 }
        guard Array(entries.prefix(live.count)) == live.map({ Optional($0) }) else {
            throw KSPError.value(
                "item \(item) pattern \(pattern) slot \(slot) has a hole in its melodic pool; "
                    + "the melodic list is compacted in every sample, so this is unmeasured "
                    + "territory")
        }
        return live
    }

    /// One drum pool chunk's note->step column, `nil` where it is empty.
    ///
    /// Unlike the melodic list this one may legitimately hold holes -- the device leaves one behind
    /// when a lane is cleared and scans past it -- so this returns the whole chunk rather than a
    /// live prefix, and a writer fills the first gap instead of appending after it.
    static func drumPool(_ raw: RawProject, _ pattern: Int, _ slot: Int) -> [Int?] {
        (0..<Constants.maxSteps).map { index -> Int? in
            guard
                case .int(let value)? = raw[
                    Keys.key(
                        Constants.drumTrackItemID, Constants.pDrumNoteStep, pattern, slot,
                        index + 1)]
            else { return nil }
            return value == Constants.sentinel ? nil : value
        }
    }

    // MARK: - Melodic notes

    /// The key holding one melodic note's pitch, by 1-based pool ordinal.
    public static func pitchKey(track: Int, pattern: Int, note: Int, slot: Int = 1) throws -> String
    {
        let item = try Keys.itemForTrack(track)
        try checkPattern(pattern)
        try checkSlot(item, slot)
        guard 1...Constants.maxSteps ~= note else {
            throw KSPError.value("note ordinal \(note) out of range 1-\(Constants.maxSteps)")
        }
        return Keys.key(item, Constants.pSeqPitch, pattern, slot, note)
    }

    /// Change one existing note's pitch. Exactly one key moves.
    ///
    /// Throws if that pool entry is empty: a pitch on a note that is not there is a pitch nothing
    /// plays, so it means the wrong ordinal was addressed -- which is the failure this surfaces.
    public static func setPitch(
        _ raw: RawProject, track: Int, pattern: Int, note: Int, pitch: Int, slot: Int = 1
    ) throws -> RawProject {
        try checkValue("pitch", pitch)
        let target = try pitchKey(track: track, pattern: pattern, note: note, slot: slot)
        let item = try Keys.itemForTrack(track)

        if case .int(Constants.sentinel)? = raw[
            Keys.key(item, Constants.pSeqNoteStep, pattern, slot, note)]
        {
            throw KSPError.value(
                "track \(track) pattern \(pattern) slot \(slot) has no note at ordinal \(note)")
        }
        return try withValues(raw, [target: pitch])
    }

    /// The keys one melodic note writes, without copying the project.
    ///
    /// ``placeNote`` is this plus a copy. A converter placing hundreds applies these to a working
    /// dictionary of its own instead, so the whole key set is not copied per note.
    public static func noteUpdates(
        _ raw: RawProject, track: Int, pattern: Int, step: Int, pitch: Int,
        velocity: Int = Constants.freshVelocity, gate: Int = Constants.defaultGateStored,
        timeShift: Int = Constants.timeShiftCentre, randomness: Int = Constants.freshRandomness,
        slot: Int? = nil, activate: Bool = true
    ) throws -> [String: Int] {
        let item = try Keys.itemForTrack(track)
        try checkPattern(pattern)
        if let slot { try checkSlot(item, slot) }
        guard 1...Constants.maxSteps ~= step else {
            throw KSPError.value("step \(step) out of range 1-\(Constants.maxSteps)")
        }
        for (name, value) in [
            ("pitch", pitch), ("velocity", velocity), ("gate", gate), ("randomness", randomness),
        ] {
            try checkValue(name, value)
        }
        try checkTimeShift(timeShift)

        let perSlot = try (1...slots).map { try slotSteps(raw, item, pattern, $0) }
        let pooled = perSlot.flatMap { $0 }
        if pooled.count >= Constants.poolCapacity {
            throw KSPError.value(
                "track \(track) pattern \(pattern) already holds \(Constants.poolCapacity) notes, "
                    + "the firmware's per-pattern limit")
        }
        if pooled.filter({ $0 == step - 1 }).count >= Constants.maxNotesPerStep {
            throw KSPError.value(
                "step \(step) already holds \(Constants.maxNotesPerStep) notes, the firmware's "
                    + "per-step limit")
        }

        // The pool is one flat list chunked into slots of 64, so "the next free ordinal" spans
        // them: a chord straddling a chunk boundary is ordinary.
        let chosen =
            slot
            ?? (perSlot.firstIndex { $0.count < Constants.maxSteps }.map { $0 + 1 } ?? slots)
        if perSlot[chosen - 1].count >= Constants.maxSteps {
            throw KSPError.value("track \(track) pattern \(pattern) slot \(chosen) is full")
        }

        // slotSteps has already established the pool is compacted, so the live count is the first
        // free ordinal.
        let ordinal = perSlot[chosen - 1].count + 1

        let values = [step - 1, pitch, gate, velocity, timeShift, randomness]
        var updates: [String: Int] = [:]
        for (param, value) in zip(noteParams, values) {
            updates[Keys.key(item, param, pattern, chosen, ordinal)] = value
        }
        updates[Keys.key(item, Constants.pPatternDataState, pattern)] = Constants.patternHasData
        if activate {
            updates[Keys.key(item, Constants.pSeqStepActive, pattern, 1, step)] = 1
        }
        return updates
    }

    /// Add a melodic note at `step` (1-based), at the first free pool ordinal.
    ///
    /// `activate: false` leaves the step-active flag clear, which places a note the device will not
    /// sound. It exists to build the M4.1 control note and a converter must never use it.
    public static func placeNote(
        _ raw: RawProject, track: Int, pattern: Int, step: Int, pitch: Int,
        velocity: Int = Constants.freshVelocity, gate: Int = Constants.defaultGateStored,
        timeShift: Int = Constants.timeShiftCentre, randomness: Int = Constants.freshRandomness,
        slot: Int? = nil, activate: Bool = true
    ) throws -> RawProject {
        try withValues(
            raw,
            noteUpdates(
                raw, track: track, pattern: pattern, step: step, pitch: pitch, velocity: velocity,
                gate: gate, timeShift: timeShift, randomness: randomness, slot: slot,
                activate: activate))
    }

    // MARK: - Drum notes

    /// The keys one drum hit writes. The drum twin of ``noteUpdates``.
    ///
    /// Track 1 only, because item 123 is the only one carrying a drum set. What differs from the
    /// melodic recipe is the step-active array: `52` is packed seven steps to an entry and
    /// addressed **by lane**, so the bit is read, or-ed and written back rather than assigned --
    /// assigning it would clear every other lane sharing that entry.
    public static func drumNoteUpdates(
        _ raw: RawProject, pattern: Int, lane: Int, step: Int,
        velocity: Int = Constants.freshVelocity, gate: Int = Constants.defaultGateStored,
        timeShift: Int = Constants.timeShiftCentre, randomness: Int = Constants.freshRandomness,
        slot: Int? = nil, activate: Bool = true
    ) throws -> [String: Int] {
        let item = Constants.drumTrackItemID
        try checkPattern(pattern)
        if let slot { try checkSlot(item, slot) }
        guard 0..<Constants.drumLaneCount ~= lane else {
            throw KSPError.value(
                "drum lane \(lane) out of range 0-\(Constants.drumLaneCount - 1)")
        }
        guard 1...Constants.maxSteps ~= step else {
            throw KSPError.value("step \(step) out of range 1-\(Constants.maxSteps)")
        }
        for (name, value) in [
            ("velocity", velocity), ("gate", gate), ("randomness", randomness),
        ] {
            try checkValue(name, value)
        }
        try checkTimeShift(timeShift)

        let perSlot = (1...slots).map { drumPool(raw, pattern, $0) }
        let pooled = perSlot.flatMap { $0 }.compactMap { $0 }
        if pooled.count >= Constants.poolCapacity {
            throw KSPError.value(
                "drum pattern \(pattern) already holds \(Constants.poolCapacity) hits, the "
                    + "firmware's per-pattern limit")
        }
        if pooled.filter({ $0 == step - 1 }).count >= Constants.maxNotesPerStep {
            throw KSPError.value(
                "step \(step) already holds \(Constants.maxNotesPerStep) hits, the firmware's "
                    + "per-step limit")
        }

        let chosen =
            slot ?? (perSlot.firstIndex { $0.contains(nil) }.map { $0 + 1 } ?? slots)
        let chunk = perSlot[chosen - 1]
        guard let free = chunk.firstIndex(of: nil) else {
            throw KSPError.value("drum pattern \(pattern) slot \(chosen) is full")
        }
        let ordinal = free + 1

        let values = [step - 1, lane, gate, velocity, timeShift, randomness]
        var updates: [String: Int] = [:]
        for (param, value) in zip(drumNoteParams, values) {
            updates[Keys.key(item, param, pattern, chosen, ordinal)] = value
        }
        updates[Keys.key(item, Constants.pPatternDataState, pattern)] = Constants.patternHasData

        if activate {
            let (i2, i3, bit) = Constants.drumStepActiveIndices(lane: lane, step: step - 1)
            let target = Keys.key(item, Constants.pDrumStepActive, pattern, i2, i3)
            guard case .int(let current)? = raw[target] else {
                throw KSPError.key("not in the file: \(target)")
            }
            updates[target] = current | 1 << bit
        }
        return updates
    }

    /// Add a drum hit on `lane` at `step` (1-based), at the first free ordinal.
    public static func placeDrumNote(
        _ raw: RawProject, pattern: Int, lane: Int, step: Int,
        velocity: Int = Constants.freshVelocity, gate: Int = Constants.defaultGateStored,
        timeShift: Int = Constants.timeShiftCentre, randomness: Int = Constants.freshRandomness,
        slot: Int? = nil, activate: Bool = true
    ) throws -> RawProject {
        try withValues(
            raw,
            drumNoteUpdates(
                raw, pattern: pattern, lane: lane, step: step, velocity: velocity, gate: gate,
                timeShift: timeShift, randomness: randomness, slot: slot, activate: activate))
    }

    // MARK: - Pattern scalars

    /// Set one pattern's step size in `99`, leaving the field's other bits.
    ///
    /// Bits 3-4 only (spec 3.3, protocol T5.1). Triplet, polyrhythm and direction are the user's
    /// settings on the device and are not ours to overwrite, which is why this reads the stored
    /// value rather than composing a fresh one. `drum: true` writes `116`, which shares the layout.
    public static func setStepSize(
        _ raw: RawProject, track: Int, pattern: Int, stepsPerBeat: Int, drum: Bool = false
    ) throws -> RawProject {
        let item = try Keys.itemForTrack(track)
        try checkPattern(pattern)
        let param = drum ? Constants.pDrumPatternBits : Constants.pSeqPatternBits
        let target = Keys.key(item, param, pattern)
        guard case .int(let stored)? = raw[target] else {
            throw KSPError.key("not in the file: \(target)")
        }
        return try withValues(
            raw, [target: Constants.stepsPerBeatBits(stored, stepsPerBeat: stepsPerBeat)])
    }

    /// Set how many steps one pattern runs for. Stored 0-based (spec 3.3).
    public static func setStepCount(
        _ raw: RawProject, track: Int, pattern: Int, steps: Int, drum: Bool = false
    ) throws -> RawProject {
        let item = try Keys.itemForTrack(track)
        try checkPattern(pattern)
        guard 1...Constants.maxSteps ~= steps else {
            throw KSPError.value("step count \(steps) out of range 1-\(Constants.maxSteps)")
        }
        let param = drum ? Constants.pDrumStepCount : Constants.pSeqStepCount
        return try withValues(
            raw, [Keys.key(item, param, pattern): steps - Constants.stepCountOffset])
    }

    /// Set one pattern's swing, as the percentage the device displays.
    ///
    /// Written per pattern (`97` / `114`) and never to the global `74`: the per-pattern value takes
    /// precedence on the device, so a groove written to the global would simply not play.
    public static func setSwing(
        _ raw: RawProject, track: Int, pattern: Int, percent: Int, drum: Bool = false
    ) throws -> RawProject {
        let item = try Keys.itemForTrack(track)
        try checkPattern(pattern)
        let (low, high) = Constants.swingRangePercent
        guard low...high ~= percent else {
            throw KSPError.value("swing \(percent)% out of range \(low)-\(high)%")
        }
        let param = drum ? Constants.pDrumSwing : Constants.pSeqSwing
        return try withValues(
            raw, [Keys.key(item, param, pattern): percent - Constants.swingOffset])
    }

    /// Set `86` bit 6, the flag deciding which note set a track plays.
    ///
    /// Track-level, and read-modify-write: the rest of `86` is the user's state. Only Track 1
    /// carries a drum set, so turning the flag *on* anywhere else would select an ARP mode whose
    /// notes we did not write.
    public static func setDrumMode(_ raw: RawProject, track: Int, on: Bool) throws -> RawProject {
        let item = try Keys.itemForTrack(track)
        if on && item != Constants.drumTrackItemID {
            throw KSPError.value(
                "track \(track) has no drum parameter set; bit 6 there is ARP, not DRUM (spec 5)")
        }
        let target = Keys.key(item, Constants.pTrackModeBits)
        guard case .int(let stored)? = raw[target] else {
            throw KSPError.key("not in the file: \(target)")
        }
        let bit = 1 << Constants.drumModeBit
        return try withValues(raw, [target: on ? stored | bit : stored & ~bit])
    }

    /// Set the project tempo, held as BPM x 100 in three 7-bit chunks.
    public static func setTempo(_ raw: RawProject, bpm: Double) throws -> RawProject {
        let hundredths = Arithmetic.pyRound(bpm * Double(Constants.tempoScale))
        let limit = Constants.tempoChunk * Constants.tempoChunk * Constants.tempoChunk
        guard 0..<limit ~= hundredths else {
            throw KSPError.value(
                "tempo \(bpm) BPM does not fit the three 7-bit chunks of 70-72")
        }
        let chunks = [Constants.pTempoLSB, Constants.pTempoMIDSB, Constants.pTempoMSB]
        var updates: [String: Int] = [:]
        for (n, param) in chunks.enumerated() {
            var divisor = 1
            for _ in 0..<n { divisor *= Constants.tempoChunk }
            updates[Keys.key(Constants.itemProject, param)] =
                Arithmetic.floorDiv(hundredths, divisor) % Constants.tempoChunk
        }
        return try withValues(raw, updates)
    }

    /// Chain `patterns` (1-based, in play order) for one track of one scene.
    ///
    /// Written contiguously from slot 1 with every remaining slot left at the sentinel, which is
    /// the shape capture T5-chain-3 produced. This is how a sequence longer than one pattern is
    /// played as one: the device stores no arrangement beyond it.
    public static func setChain(
        _ raw: RawProject, scene: Int, track: Int, patterns: [Int]
    ) throws -> RawProject {
        guard 1...Constants.sceneCount ~= scene else {
            throw KSPError.value("scene \(scene) out of range 1-\(Constants.sceneCount)")
        }
        guard 1...Constants.sceneTrackCount ~= track else {
            throw KSPError.value("track \(track) out of range 1-\(Constants.sceneTrackCount)")
        }
        guard patterns.count <= Constants.chainSlots else {
            throw KSPError.value("a chain holds at most \(Constants.chainSlots) patterns")
        }
        for pattern in patterns {
            try checkPattern(pattern)
        }

        let stored = patterns.map { $0 - 1 }
        let padded =
            stored
            + Array(
                repeating: Constants.sentinel, count: Constants.chainSlots - stored.count)
        var updates: [String: Int] = [:]
        for (index, value) in padded.enumerated() {
            updates[
                Keys.key(Constants.itemScenes, Constants.pSceneChain, scene, track, index + 1)] =
                value
        }
        return try withValues(raw, updates)
    }
}
