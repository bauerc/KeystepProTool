/// Targeted edits to a parsed `.KeyStepPro` project. Placing one melodic note costs 8 keys, not
/// one (spec 4); step skip (`49`) is deliberately not written, since a file already holds 15
/// everywhere. Nothing here adds or removes a key: the key set is fixed (spec 2).
public enum Mutate {
    /// Pool chunks a melodic note may occupy. Track 1's fourth is a phantom the firmware never uses.
    static let slots = Constants.poolSlots

    static let noteParams = [
        Constants.pSeqNoteStep, Constants.pSeqPitch, Constants.pSeqGate, Constants.pSeqVelocity,
        Constants.pSeqTimeShift, Constants.pSeqRandomness,
    ]

    /// The drum set in the same order, so one recipe serves both; `117` holds a lane, `109` a pitch.
    static let drumNoteParams = [
        Constants.pDrumNoteStep, Constants.pDrumPitch, Constants.pDrumGate,
        Constants.pDrumVelocity, Constants.pDrumTimeShift, Constants.pDrumRandomness,
    ]

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

    /// Copy `raw` with `updates` applied; a key the file lacks means the address was miscomputed.
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

    /// Apply `updates` in place: a bulk writer cannot afford a copy of 153,495 keys per note.
    public static func mergeUpdates(_ raw: inout RawProject, _ updates: [String: Int]) throws {
        let missing = updates.keys.filter { raw[$0] == nil }
        if !missing.isEmpty {
            throw KSPError.key("not in the file: \(missing.sorted().joined(separator: ", "))")
        }
        for (name, value) in updates {
            raw[name] = .int(value)
        }
    }

    /// The 0-based step of each live pool entry in one slot. Throws on a hole: the melodic pool
    /// is compacted in every sample, so appending past one is unmeasured (spec 4).
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

    /// One drum pool chunk's note->step column, `nil` where empty. The drum pool may hold holes,
    /// so this is the whole chunk and a writer fills the first gap rather than appending.
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

    /// Change one existing note's pitch. Throws on an empty pool entry: nothing would play it.
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

    /// The keys one melodic note writes, without copying the project; ``placeNote`` adds the copy.
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
        if pooled.count(where: { $0 == step - 1 }) >= Constants.maxNotesPerStep {
            throw KSPError.value(
                "step \(step) already holds \(Constants.maxNotesPerStep) notes, the firmware's "
                    + "per-step limit")
        }

        // The pool is one flat list chunked into slots of 64, so the next free ordinal spans them.
        let chosen =
            slot
            ?? (perSlot.firstIndex { $0.count < Constants.maxSteps }.map { $0 + 1 } ?? slots)
        if perSlot[chosen - 1].count >= Constants.maxSteps {
            throw KSPError.value("track \(track) pattern \(pattern) slot \(chosen) is full")
        }

        // slotSteps established the pool is compacted, so the live count is the first free ordinal.
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

    /// Add a melodic note at `step` (1-based), at the first free pool ordinal. `activate: false`
    /// places a note the device will not sound, which no converter should want.
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

    /// The keys one drum hit writes, on track 1 only. `52` packs seven steps per entry by lane, so
    /// its bit is or-ed in: assigning would clear every other lane sharing that entry.
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
        if pooled.count(where: { $0 == step - 1 }) >= Constants.maxNotesPerStep {
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

    /// Set one pattern's step size in `99`, bits 3-4 only: triplet, polyrhythm and direction are
    /// the user's settings. `drum: true` writes `116`, which shares the layout.
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

    /// Set one pattern's swing, as the percentage the device displays. Never the global `74`: the
    /// per-pattern value takes precedence, so a groove written there would not play.
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

    /// Set `86` bit 6, deciding which note set a track plays. Read-modify-write, since the rest
    /// of `86` is the user's state; only track 1 has a drum set to select.
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

    /// Chain `patterns` (1-based, in play order) for one track of one scene, written contiguously
    /// from slot 1 with the remaining slots left at the sentinel.
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
