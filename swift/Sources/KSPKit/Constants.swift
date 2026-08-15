/// Item IDs, parameter IDs and encodings from the KeyStep Pro format spec.
///
/// A port of `src/ksp/constants.py`, which carries the provenance for every value here: each one
/// traces to a table in `analysis/KeyStepPro_Format_Spec.md` or to a named capture. Nothing is
/// inferred or invented -- where an encoding is not yet known, both files say so.
public enum Constants {
    /// The `version` string every user-saved project carries and the factory `Default.KeyStepPro`
    /// lacks (spec section 2).
    public static let projectVersion = "2.5.20"

    /// "Empty" marker in note-indexed arrays. Also a legal pitch and a legal velocity, which is
    /// why note existence is tested on the note->step parameter alone and never on velocity.
    public static let sentinel = 127

    // MARK: - Item IDs (spec section 2)

    public static let itemProject = 120
    public static let itemScenes = 121
    public static let itemControlTrack = 122

    /// Sequencer tracks 1-4. Track 1 (item 123) carries a full drum parameter set in addition to
    /// the melodic one.
    public static let trackItemIDs = [123, 124, 125, 126]
    public static let drumTrackItemID = 123

    public static let patternsPerTrack = 16
    public static let maxSteps = 64

    // MARK: - Scenes and pattern chaining (item 121)

    public static let sceneCount = 16

    /// Chain slots per (scene, track) -- one per pattern the chain can hold.
    public static let chainSlots = 16

    /// Tracks addressed by a scene key: 1-4 are the sequencer tracks and 5 is the Control track,
    /// which is the one place the item ordering is not the obvious one.
    public static let sceneTrackCount = 5
    public static let controlTrackIndex = 5

    public static let pSceneChain = 84

    /// Moves 0 -> 32 alongside the chain. One capture cannot separate `(last << 4) | first` from
    /// `(len - 1) << 4`, so nothing reads it.
    public static let pScenePatternState = 83

    /// Pool chunks per track -- *not* polyphony voices. Track 1's fourth chunk is the phantom the
    /// firmware never uses; see `reader.slot_is_initialised`.
    public static let slotsByItem = [123: 4, 124: 3, 125: 3, 126: 3]

    /// Pool chunks a note may actually occupy, on every track.
    public static let poolSlots = 3

    /// Usable pool capacity, ignoring Track 1's phantom fourth chunk.
    public static let poolCapacity = poolSlots * maxSteps

    // MARK: - Project / global parameters (spec section 3.4)

    public static let pTempoLSB = 70
    public static let pTempoMIDSB = 71
    public static let pTempoMSB = 72
    public static let pGlobalSwing = 74
    public static let pCurrentScene = 75

    /// Tempo is a 21-bit little-endian value in 7-bit chunks, holding BPM x 100.
    public static let tempoChunk = 128
    public static let tempoScale = 100

    /// What the device itself will run at. The three chunks reach about 20,971 BPM, so the field's
    /// width is no guide: anything outside this is a project the hardware cannot play.
    public static let tempoRangeBPM = (min: 30.0, max: 240.0)

    // MARK: - Per-pattern scalars (spec section 3.3), indexed by pattern 1-16

    public static let pPatternDataState = 40
    public static let pSeqSwing = 97
    public static let pSeqStepCount = 98
    public static let pSeqPatternBits = 99
    public static let pModeBits = 100
    public static let pRootNote = 107
    public static let pScale = 108
    public static let pDrumSwing = 114
    public static let pDrumStepCount = 115
    public static let pDrumPatternBits = 116

    /// `40` is 3 where a pattern holds data and 2 where it does not.
    public static let patternHasData = 3

    /// Swing is stored with a +25 offset: stored 25 is 50% (no swing), stored 50 is 75%.
    public static let swingOffset = 25

    /// The displayed swing range. 50% is straight, and is both the minimum and the default, so
    /// swing only ever delays.
    public static let swingRangePercent = (min: 50, max: 75)

    /// Step counts are 0-based: stored 15 means a 16-step pattern.
    public static let stepCountOffset = 1

    // MARK: - The per-pattern bitfield (99 / 116)

    // Measured 2026-08-04, protocol tier 5. The sequencer field and the drum field share one
    // layout; only their defaults differ, which is the whole of the 20-vs-16 asymmetry.

    /// Bit 0. Displayed as Triplet.
    public static let tripletBit = 0

    /// Bit 2. Set = Polyrhythm, clear = Monorhythm. Sequencer patterns default to set, drum
    /// patterns to clear.
    public static let polyrhythmBit = 2

    /// Bits 3-4, indexing ``stepSizeDenominators``.
    public static let stepSizeShift = 3
    public static let stepSizeMask = 0b11

    /// Step size by stored index: 1/4, 1/8, 1/16, 1/32. 1/16 (index 2) is the device default.
    public static let stepSizeDenominators = [4, 8, 16, 32]

    /// Bits 5-6. 3 was never produced by the device and has no known name.
    public static let directionShift = 5
    public static let directionMask = 0b11
    public static let directionForward = 0
    public static let directionRandom = 1
    public static let directionWalk = 2

    /// Bit 1 is set by nothing: not in any sample project, not in any capture.
    private static let allocatedBits =
        1 << tripletBit | 1 << polyrhythmBit | stepSizeMask << stepSizeShift
        | directionMask << directionShift

    /// Step size as a note denominator: 16 means 1/16 steps.
    public static func stepDenominator(_ bits: Int) -> Int {
        stepSizeDenominators[(bits >> stepSizeShift) & stepSizeMask]
    }

    public static func isTriplet(_ bits: Int) -> Bool {
        bits & 1 << tripletBit != 0
    }

    public static func isPolyrhythm(_ bits: Int) -> Bool {
        bits & 1 << polyrhythmBit != 0
    }

    public static func directionIndex(_ bits: Int) -> Int {
        (bits >> directionShift) & directionMask
    }

    /// Bits set that tier 5 never accounted for. Non-zero means a value the captures did not
    /// produce, which callers report rather than interpret.
    public static func unallocatedBits(_ bits: Int) -> Int {
        bits & ~allocatedBits
    }

    /// Parameter 108 indexes the device's scale list in display order.
    ///
    /// Index 7 (Root) is in the list but **cannot be stored**: selecting it leaves 108 at its
    /// previous value, so a file never holds 7. Kept so the remaining indices line up.
    public static let scaleNames = [
        "Chromatic", "Major", "Minor", "Dorian", "Mixolydian", "Harmonic Minor", "Blues", "Root",
        "User 1", "User 2",
    ]

    /// The one entry of ``scaleNames`` the device declines to store (T5.6).
    public static let unstorableScale = 7

    /// Name parameter 108's value, or `nil` if it is off the list.
    public static func scaleName(_ stored: Int) -> String? {
        scaleNames.indices.contains(stored) ? scaleNames[stored] : nil
    }

    /// Root note is a pitch class, 0-11; the octave the display shows is kept nowhere in the file.
    public static let rootNoteCount = 12

    // MARK: - Melodic note parameters (spec section 3.1)

    // 48 and 49 are indexed by step; 50 and 109-113 are indexed by note ordinal. Conflating the
    // two index spaces is the classic way to misread this format.

    public static let pSeqStepActive = 48  // step-indexed
    public static let pSeqStepSkip = 49  // step-indexed
    public static let pSeqNoteStep = 50  // note-indexed, 0-based step
    public static let pSeqPitch = 109
    public static let pSeqGate = 110
    public static let pSeqVelocity = 111
    public static let pSeqTimeShift = 112
    public static let pSeqRandomness = 113  // play probability, not timing jitter

    // MARK: - Drum note parameters, item 123 only (spec section 3.2)

    public static let pDrumPolyStepCount = 51
    public static let pDrumStepActive = 52  // flattened lane-major bit array, see below
    public static let pDrumStepSkip = 53  // note-indexed, unlike the melodic 49
    public static let pDrumNoteStep = 54  // note-indexed, 0-based step
    public static let pDrumPitch = 117  // drum lane index, 0-based (0 = kick)
    public static let pDrumGate = 118
    public static let pDrumVelocity = 119
    public static let pDrumTimeShift = 120
    public static let pDrumRandomness = 121

    /// The device has 24 drum lanes, derived from MCC's parameter dictionary. No array in the
    /// project file has this cardinality -- the lane is a *value* of parameter 117, never an index.
    public static let drumLaneCount = 24

    /// Per-track bitfield. Bit 6 is the Arp/Drum mode state, and is track-level rather than
    /// per-pattern, which matches the device's Drum button.
    public static let pTrackModeBits = 86
    public static let drumModeBit = 6

    // MARK: - The drum step-active bit array (parameter 52)

    // Neither step-indexed nor note-indexed: a flattened [lane][part] bit array, lane-major,
    // whose two trailing indices are storage geometry rather than lane and step (spec section 4).

    /// Steps per stored entry. Seven, not eight -- the values are 7-bit like every other field.
    public static let drumStepActiveBitsPerEntry = 7

    /// Entries per lane: 10 x 7 = 70, enough to cover all 64 steps.
    public static let drumStepActivePartsPerLane = 10

    /// Locate the step-active bit for `lane` (0-based) at `step` (0-based).
    ///
    /// Returns the two 1-based file indices and the 0-based bit position, i.e. the bit lives in
    /// `123_52_<pattern>_<slot>_<index>` at `1 << bit`.
    public static func drumStepActiveIndices(lane: Int, step: Int) -> (
        slot: Int, index: Int, bit: Int
    ) {
        let flat = lane * drumStepActivePartsPerLane + step / drumStepActiveBitsPerEntry
        return (flat / maxSteps + 1, flat % maxSteps + 1, step % drumStepActiveBitsPerEntry)
    }

    // MARK: - Device global parameters (spec section 3.4)

    // Recorded for documentation and the eventual SysEx path. These are addressed by
    // globalParamId under deviceGlobalParametersId 65 and are NOT present in any project file.

    public static let globalParamsItem = 65
    public static let gDrumOutputChannel = 79
    public static let gDrumMapMode = 81  // 0 = Chromatic, 1 = Custom
    public static let gDrumMapLowNote = 82  // chromatic mode, 0-103
    public static let gDrumMapNote1 = 83  // ..106 = Note 1..Note 24, custom mode

    // MARK: - Value encodings

    /// Time shift is an offset around a centre of 49, so stored 50 is +1 and stored 48 is -1.
    /// The drum field 120 shares it.
    public static let timeShiftCentre = 49

    /// The displayed range of time shift, in steps of 1. Asymmetric by one: there is no -50.
    public static let timeShiftRange = (min: -49, max: 50)

    /// The same bounds as stored in 112 / 120.
    public static let timeShiftStoredMin = timeShiftCentre + timeShiftRange.min
    public static let timeShiftStoredMax = timeShiftCentre + timeShiftRange.max

    /// One unit is 1/400 of a *beat*, not of the step, so the full +50 is 60 ticks at 480 PPQN
    /// whatever the step size (tier 8, `analysis/Timing_Calibration.md` section 6.1).
    public static let timeShiftUnitsPerBeat = 400

    /// The displacement of a signed `shift`, in MIDI ticks. Positive delays.
    ///
    /// Rounded because the usual 480 ticks per beat is not divisible by 400; the error is under
    /// half a tick, per note, and does not accumulate across a pattern. Halves go to even, which
    /// is what Python's `round` does and what `rounded()` alone would not.
    public static func timeShiftTicks(_ shift: Int, ticksPerBeat: Int) -> Int {
        let ticks = Double(shift) * Double(ticksPerBeat) / Double(timeShiftUnitsPerBeat)
        return Arithmetic.pyRound(ticks)
    }

    /// Step skip is a 4-bit mask over the four 16-step sequences a pattern can run as. 15 (all
    /// four) is the default. Spec section 5.
    public static let skipSequences = [16, 32, 48, 64]

    /// Gate length is an **index**, not a curve: `stored = encoder detent - 1` (spec section 6.1,
    /// transcribed in `analysis/gate_ladder.txt`). All the non-linearity lives in the *display*,
    /// which walks five runs of constant increment and closes exactly on stored 127.
    public static let gateRuns: [(count: Int, increment: Double)] = [
        (8, 0.0625), (20, 0.125), (20, 0.25), (48, 0.5), (32, 1.0),
    ]

    /// stored 0-127 -> gate length in steps. Complete: every legal 7-bit value has a measured
    /// length, so nothing is interpolated and nothing is guessed.
    ///
    /// Every increment is an exact binary fraction, so the running total is exact in `Double` and
    /// needs no rounding.
    public static let gateTable: [Double] = {
        var table: [Double] = []
        var value = 0.0
        for run in gateRuns {
            for _ in 0..<run.count {
                value += run.increment
                table.append(value)
            }
        }
        return table
    }()

    /// A freshly placed note stores gate 7, i.e. half a step (spec section 6.1). It is what a
    /// writer puts on a note the caller said nothing about.
    public static let defaultGateStored = 7
    public static let defaultGateLength = gateTable[defaultGateStored]

    /// The other two values a freshly placed note carries, measured rather than assumed.
    public static let freshVelocity = 100
    public static let freshRandomness = 100

    /// The per-step ceiling the firmware enforces on screen, inside ``poolCapacity``: a pattern
    /// holds 192 events only if they are spread across at least 12 steps.
    public static let maxNotesPerStep = 16

    /// The gate length in steps, or `nil` if `stored` is off the ladder.
    ///
    /// Every legal 7-bit value decodes, so `nil` means corrupt input -- a value outside 0-127 --
    /// not an unmeasured encoding.
    public static func decodeGate(_ stored: Int) -> Double? {
        gateTable.indices.contains(stored) ? gateTable[stored] : nil
    }

    /// The ladder rung nearest `length` steps, for a writer carrying durations.
    ///
    /// The ladder is coarse above 3 steps and its runs are not uniform, so an arbitrary MIDI
    /// duration rarely lands on a rung. Ties take the lower rung, as Python's `min` does.
    public static func encodeGate(_ length: Double) -> Int {
        gateTable.indices.min {
            (abs(gateTable[$0] - length), $0) < (abs(gateTable[$1] - length), $1)
        } ?? defaultGateStored
    }

    /// How the four sequences run: as **repeats**, not pages. A pass is the pattern's own declared
    /// length at any length, so every mask is meaningful even on a pattern far shorter than 64.
    public static let skipCyclePasses = skipSequences.count

    /// Every sequence set, i.e. a note that plays on all four passes.
    public static let skipMaskAll = (1 << skipCyclePasses) - 1

    /// Steps per beat when the pattern runs at 1/16, the device default. Only the *import*
    /// direction has to choose this -- an export reads the pattern's own step size out of 99/116.
    public static let defaultStepsPerBeat = 4

    /// Shared by every caller that lets a user pick one, so the message cannot drift.
    public static func checkStepsPerBeat(_ value: Int) throws {
        if value < 1 {
            throw KSPError.value("steps_per_beat must be at least 1")
        }
    }

    /// Set the step-size field of `bits` to `stepsPerBeat`, leaving the rest.
    ///
    /// Throws for a step size the device cannot express: the field is two bits wide and holds
    /// 1/4 through 1/32 only.
    public static func stepsPerBeatBits(_ bits: Int, stepsPerBeat: Int) throws -> Int {
        let denominator = stepsPerBeat * 4
        guard let index = stepSizeDenominators.firstIndex(of: denominator) else {
            let sizes = stepSizeDenominators.map { "1/\($0)" }.joined(separator: ", ")
            throw KSPError.value(
                "1/\(denominator) steps cannot be stored; the device holds \(sizes) "
                    + "in parameter 99 (spec 3.3)"
            )
        }
        return bits & ~(stepSizeMask << stepSizeShift) | index << stepSizeShift
    }

    /// The 16/32/48/64 sequences a note plays in: `15` -> all four (the default); `5` -> 16 and
    /// 48; `12` -> 48 and 64.
    public static func decodeSkipMask(_ mask: Int) -> [Int] {
        skipSequences.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
    }

    /// The KeyStep Pro displays middle C (MIDI 60) as C3: project_5 documents pitch 48 as C2 and
    /// project_9 documents pitch 60 as C3.
    private static let noteNames = [
        "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
    ]

    /// Render a MIDI pitch the way the hardware labels it, e.g. 48 -> `C2`.
    public static func noteName(_ pitch: Int) -> String {
        "\(noteNames[Arithmetic.floorMod(pitch, 12)])\(Arithmetic.floorDiv(pitch, 12) - 2)"
    }

    /// Name parameter 107's pitch class, e.g. 2 -> `D`. No octave: the display shows one but the
    /// file does not store it (T5.6).
    public static func rootNoteName(_ root: Int) -> String {
        noteNames[Arithmetic.floorMod(root, rootNoteCount)]
    }
}
