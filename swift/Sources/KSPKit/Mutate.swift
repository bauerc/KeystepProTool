/// Placing one melodic note costs 8 keys, not one (spec 4). Nothing here adds or removes a key.
public enum Mutate {
    static let slots = Constants.poolSlots

    static let noteParams = [
        Constants.pSeqNoteStep, Constants.pSeqPitch, Constants.pSeqGate, Constants.pSeqVelocity,
        Constants.pSeqTimeShift, Constants.pSeqRandomness,
    ]

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

    private static func signed(_ value: Int) -> String {
        value < 0 ? "\(value)" : "+\(value)"
    }

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

    public static func mergeUpdates(_ raw: inout RawProject, _ updates: [String: Int]) throws {
        let missing = updates.keys.filter { raw[$0] == nil }
        if !missing.isEmpty {
            throw KSPError.key("not in the file: \(missing.sorted().joined(separator: ", "))")
        }
        for (name, value) in updates {
            raw[name] = .int(value)
        }
    }

    /// Throws on a hole: the melodic pool is compacted, so appending past one is unmeasured.
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

    /// The drum pool may hold holes, so a writer fills the first gap rather than appending.
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

        let chosen =
            slot
            ?? (perSlot.firstIndex { $0.count < Constants.maxSteps }.map { $0 + 1 } ?? slots)
        if perSlot[chosen - 1].count >= Constants.maxSteps {
            throw KSPError.value("track \(track) pattern \(pattern) slot \(chosen) is full")
        }

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

    /// `52` packs seven steps per entry by lane, so its bit is or-ed in, never assigned.
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

    /// Never the global `74`, which the per-pattern value overrides on the device.
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
