/// Item IDs, parameter IDs and encodings from the KeyStep Pro format spec.
public enum Constants {
    /// Carried by every user-saved project; the factory default lacks it (spec 2).
    public static let projectVersion = "2.5.20"

    /// "Empty" marker in note-indexed arrays, and also a legal pitch and velocity.
    public static let sentinel = 127

    /// Item IDs (spec 2).
    public static let itemProject = 120
    public static let itemScenes = 121
    public static let itemControlTrack = 122

    /// Sequencer tracks 1-4; track 1 (item 123) also carries a full drum parameter set.
    public static let trackItemIDs = [123, 124, 125, 126]
    public static let drumTrackItemID = 123

    public static let patternsPerTrack = 16
    public static let maxSteps = 64

    /// Project slots a user can name; the protocol's own slot byte is wider (``Sysex.maxSlot``).
    public static let projectSlots = 16

    /// Scenes and pattern chaining, item 121.
    public static let sceneCount = 16

    /// Chain slots per (scene, track), one per pattern the chain can hold.
    public static let chainSlots = 16

    /// Tracks addressed by a scene key: 1-4 sequencer, 5 Control.
    public static let sceneTrackCount = 5
    public static let controlTrackIndex = 5

    public static let pSceneChain = 84

    /// Moves 0 -> 32 alongside the chain; its encoding is ambiguous, so nothing reads it.
    public static let pScenePatternState = 83

    /// Pool chunks per track, not polyphony voices. Track 1's 4th is a phantom (spec 4).
    public static let slotsByItem = [123: 4, 124: 3, 125: 3, 126: 3]

    /// Pool chunks a note may actually occupy, on every track.
    public static let poolSlots = 3

    /// Usable pool capacity, ignoring track 1's phantom fourth chunk.
    public static let poolCapacity = poolSlots * maxSteps

    /// Project / global parameters (spec 3.4).
    public static let pTempoLSB = 70
    public static let pTempoMIDSB = 71
    public static let pTempoMSB = 72
    public static let pGlobalSwing = 74
    public static let pCurrentScene = 75

    /// Tempo is a 21-bit little-endian value in 7-bit chunks, holding BPM x 100.
    public static let tempoChunk = 128
    public static let tempoScale = 100

    /// What the device will run at; the three chunks reach far wider, so the field width is no guide.
    public static let tempoRangeBPM = (min: 30.0, max: 240.0)

    /// Per-pattern scalars (spec 3.3), indexed by pattern 1-16.
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

    /// Swing carries a +25 offset: stored 25 is 50% (straight), stored 50 is 75%.
    public static let swingOffset = 25

    /// 50% is straight, and is both the minimum and the default, so swing only ever delays.
    public static let swingRangePercent = (min: 50, max: 75)

    /// Step counts are 0-based: stored 15 means a 16-step pattern.
    public static let stepCountOffset = 1

    /// Bit 0 of the per-pattern bitfield (99 / 116). Displayed as Triplet.
    public static let tripletBit = 0

    /// Bit 2. Set = Polyrhythm, clear = Monorhythm; sequencer defaults set, drum clear.
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

    /// Bits no measurement accounted for; callers report these rather than interpret them.
    public static func unallocatedBits(_ bits: Int) -> Int {
        bits & ~allocatedBits
    }

    /// Parameter 108 indexes this list in display order; index 7 (Root) cannot be stored.
    public static let scaleNames = [
        "Chromatic", "Major", "Minor", "Dorian", "Mixolydian", "Harmonic Minor", "Blues", "Root",
        "User 1", "User 2",
    ]

    /// The one entry of ``scaleNames`` the device declines to store.
    public static let unstorableScale = 7

    /// Name parameter 108's value, or `nil` if it is off the list.
    public static func scaleName(_ stored: Int) -> String? {
        scaleNames.indices.contains(stored) ? scaleNames[stored] : nil
    }

    /// Root note is a pitch class, 0-11; the octave the display shows is stored nowhere.
    public static let rootNoteCount = 12

    /// Melodic note parameters (spec 3.1). 48 and 49 are step-indexed; 50 and 109-113 are
    /// note-indexed, and conflating the two index spaces is the classic way to misread this format.
    public static let pSeqStepActive = 48  // step-indexed
    public static let pSeqStepSkip = 49  // step-indexed
    public static let pSeqNoteStep = 50  // note-indexed, 0-based step
    public static let pSeqPitch = 109
    public static let pSeqGate = 110
    public static let pSeqVelocity = 111
    public static let pSeqTimeShift = 112
    public static let pSeqRandomness = 113  // play probability, not timing jitter

    /// Drum note parameters, item 123 only (spec 3.2).
    public static let pDrumPolyStepCount = 51
    public static let pDrumStepActive = 52  // flattened lane-major bit array, see below
    public static let pDrumStepSkip = 53  // note-indexed, unlike the melodic 49
    public static let pDrumNoteStep = 54  // note-indexed, 0-based step
    public static let pDrumPitch = 117  // drum lane index, 0-based (0 = kick)
    public static let pDrumGate = 118
    public static let pDrumVelocity = 119
    public static let pDrumTimeShift = 120
    public static let pDrumRandomness = 121

    /// The lane is a *value* of parameter 117, never an index: no array has this cardinality.
    public static let drumLaneCount = 24

    /// Per-track bitfield; bit 6 is the Arp/Drum mode state, track-level rather than per-pattern.
    public static let pTrackModeBits = 86
    public static let drumModeBit = 6

    /// Parameter 52 is a flattened [lane][part] bit array, lane-major (spec 4). Steps per stored
    /// entry is seven, not eight -- the values are 7-bit like every other field.
    public static let drumStepActiveBitsPerEntry = 7

    /// Entries per lane: 10 x 7 = 70, enough to cover all 64 steps.
    public static let drumStepActivePartsPerLane = 10

    /// The two 1-based file indices and 0-based bit for `lane` at `step`, both 0-based.
    public static func drumStepActiveIndices(lane: Int, step: Int) -> (
        slot: Int, index: Int, bit: Int
    ) {
        let flat = lane * drumStepActivePartsPerLane + step / drumStepActiveBitsPerEntry
        return (flat / maxSteps + 1, flat % maxSteps + 1, step % drumStepActiveBitsPerEntry)
    }

    /// Device global parameters (spec 3.4): addressed under item 65, absent from every project file.
    public static let globalParamsItem = 65
    public static let gDrumOutputChannel = 79
    public static let gDrumMapMode = 81  // 0 = Chromatic, 1 = Custom
    public static let gDrumMapLowNote = 82  // chromatic mode, 0-103
    public static let gDrumMapNote1 = 83  // ..106 = Note 1..Note 24, custom mode

    /// Time shift is an offset around a centre of 49, so stored 50 is +1. Field 120 shares it.
    public static let timeShiftCentre = 49

    /// The displayed range, in steps of 1. Asymmetric by one: there is no -50.
    public static let timeShiftRange = (min: -49, max: 50)

    /// The same bounds as stored in 112 / 120.
    public static let timeShiftStoredMin = timeShiftCentre + timeShiftRange.min
    public static let timeShiftStoredMax = timeShiftCentre + timeShiftRange.max

    /// One unit is 1/400 of a *beat*, not of the step, whatever the step size.
    public static let timeShiftUnitsPerBeat = 400

    /// The displacement of a signed `shift`, in MIDI ticks. Positive delays.
    public static func timeShiftTicks(_ shift: Int, ticksPerBeat: Int) -> Int {
        let ticks = Double(shift) * Double(ticksPerBeat) / Double(timeShiftUnitsPerBeat)
        return Arithmetic.pyRound(ticks)
    }

    /// Step skip is a 4-bit mask over the four sequences a pattern can run as (spec 5).
    public static let skipSequences = [16, 32, 48, 64]

    /// Gate length is an index, not a curve: `stored = encoder detent - 1` (spec 6.1). The
    /// non-linearity lives in the display, which walks five runs of constant increment.
    public static let gateRuns: [(count: Int, increment: Double)] = [
        (8, 0.0625), (20, 0.125), (20, 0.25), (48, 0.5), (32, 1.0),
    ]

    /// stored 0-127 -> gate length in steps. Every increment is an exact binary fraction.
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

    /// A freshly placed note stores gate 7, i.e. half a step (spec 6.1).
    public static let defaultGateStored = 7
    public static let defaultGateLength = gateTable[defaultGateStored]

    /// The other two values a freshly placed note carries.
    public static let freshVelocity = 100
    public static let freshRandomness = 100

    /// The per-step ceiling the firmware enforces on screen, inside ``poolCapacity``.
    public static let maxNotesPerStep = 16

    /// The gate length in steps; `nil` means a value outside 0-127, not an unmeasured encoding.
    public static func decodeGate(_ stored: Int) -> Double? {
        gateTable.indices.contains(stored) ? gateTable[stored] : nil
    }

    /// The ladder rung nearest `length` steps. Ties take the lower rung, as Python's `min` does.
    public static func encodeGate(_ length: Double) -> Int {
        gateTable.indices.min {
            (abs(gateTable[$0] - length), $0) < (abs(gateTable[$1] - length), $1)
        } ?? defaultGateStored
    }

    /// The four sequences run as repeats, not pages: a pass is the pattern's own declared length.
    public static let skipCyclePasses = skipSequences.count

    /// Every sequence set, i.e. a note that plays on all four passes.
    public static let skipMaskAll = (1 << skipCyclePasses) - 1

    /// The device default step size. Only import chooses this; export reads 99/116.
    public static let defaultStepsPerBeat = 4

    /// Shared by every caller that lets a user pick one, so the message cannot drift.
    public static func checkStepsPerBeat(_ value: Int) throws {
        if value < 1 {
            throw KSPError.value("steps_per_beat must be at least 1")
        }
    }

    /// Set the step-size field of `bits`, throwing for a size the two-bit field cannot express.
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

    /// The 16/32/48/64 sequences a note plays in: `15` -> all four; `5` -> 16 and 48.
    public static func decodeSkipMask(_ mask: Int) -> [Int] {
        skipSequences.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
    }

    /// The device displays middle C (MIDI 60) as C3.
    private static let noteNames = [
        "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
    ]

    /// Render a MIDI pitch the way the hardware labels it, e.g. 48 -> `C2`.
    public static func noteName(_ pitch: Int) -> String {
        "\(noteNames[Arithmetic.floorMod(pitch, 12)])\(Arithmetic.floorDiv(pitch, 12) - 2)"
    }

    /// Name parameter 107's pitch class, e.g. 2 -> `D`. The file stores no octave.
    public static func rootNoteName(_ root: Int) -> String {
        noteNames[Arithmetic.floorMod(root, rootNoteCount)]
    }
}
