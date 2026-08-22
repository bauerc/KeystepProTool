import Foundation
import Testing

@testable import KSPKit

private let track2Item = 124
private let track3Item = 125

/// What the device wrote when a human placed one note on Track 2, pattern 1, step 1, pitch 60.
private let placementRecipe: [String: (before: Int?, after: Int)] = [
    "124_40_1": (2, 3),
    "124_48_1_1_1": (0, 1),
    "124_50_1_1_1": (127, 0),
    "124_109_1_1_1": (127, 60),
    "124_110_1_1_1": (127, 7),
    "124_111_1_1_1": (127, 100),
    "124_112_1_1_1": (127, 49),
    "124_113_1_1_1": (127, 100),
]

private func changed(_ before: RawProject, _ after: RawProject) -> [String: (
    before: Int?, after: Int
)] {
    var moved: [String: (before: Int?, after: Int)] = [:]
    for (name, value) in after {
        guard case .int(let now) = value else { continue }
        if before[name] != value {
            moved[name] = (intValue(before[name]), now)
        }
    }
    return moved
}

private func intValue(_ value: JSONValue?) -> Int? {
    if case .int(let number)? = value { return number }
    return nil
}

private func intAt(_ raw: RawProject, _ name: String) -> Int? { intValue(raw[name]) }

/// Swift cannot compare tuple-valued dictionaries with `==`.
private func same(
    _ left: [String: (before: Int?, after: Int)], _ right: [String: (before: Int?, after: Int)]
) -> Bool {
    guard left.count == right.count else { return false }
    return left.allSatisfy { name, value in
        guard let other = right[name] else { return false }
        return value.before == other.before && value.after == other.after
    }
}

@Suite struct MutateRecipeTests {
    @Test func placingANoteWritesExactlyTheMeasuredRecipe() throws {
        let base = try Samples.raw("baseline.KeyStepPro")
        let placed = try Mutate.placeNote(base, track: 2, pattern: 1, step: 1, pitch: 60)
        #expect(same(changed(base, placed), placementRecipe))
    }

    /// `49` already reads 15 -- "plays on all four sequences" -- everywhere.
    @Test func stepSkipIsNotWritten() throws {
        let base = try Samples.raw("baseline.KeyStepPro")
        #expect(intAt(base, Keys.key(track2Item, Constants.pSeqStepSkip, 1, 1, 1)) == 15)

        let placed = try Mutate.placeNote(base, track: 2, pattern: 1, step: 1, pitch: 60)
        #expect(!changed(base, placed).keys.contains { $0.contains("_\(Constants.pSeqStepSkip)_") })
    }

    /// `48` is step-indexed while the pool is note-indexed: a chord shares one `48` bit.
    @Test func aChordSetsOneStepActiveBit() throws {
        let base = try Samples.raw("baseline.KeyStepPro")
        var project = base
        for pitch in [48, 52, 55] {
            project = try Mutate.placeNote(project, track: 2, pattern: 1, step: 1, pitch: pitch)
        }

        for (index, pitch) in [48, 52, 55].enumerated() {
            let ordinal = index + 1
            #expect(
                intAt(project, Keys.key(track2Item, Constants.pSeqPitch, 1, 1, ordinal)) == pitch)
            #expect(
                intAt(project, Keys.key(track2Item, Constants.pSeqNoteStep, 1, 1, ordinal)) == 0)
        }

        let active = changed(base, project).keys.filter { $0.contains("_48_") }
        #expect(active == [Keys.key(track2Item, Constants.pSeqStepActive, 1, 1, 1)])
    }

    @Test func placeNoteFillsOrdinalsFromOneWithoutGaps() throws {
        var project = try Samples.raw("baseline.KeyStepPro")
        for step in [1, 5, 9] {
            project = try Mutate.placeNote(project, track: 2, pattern: 1, step: step, pitch: 60)
        }

        let steps = (1...4).map {
            intAt(project, Keys.key(track2Item, Constants.pSeqNoteStep, 1, 1, $0))
        }
        #expect(steps == [0, 4, 8, Constants.sentinel])
    }

    @Test func placeNoteWithoutActivateLeavesTheStepDark() throws {
        let base = try Samples.raw("baseline.KeyStepPro")
        let placed = try Mutate.placeNote(
            base, track: 2, pattern: 1, step: 5, pitch: 60, activate: false)

        #expect(intAt(placed, Keys.key(track2Item, Constants.pSeqNoteStep, 1, 1, 1)) == 4)
        #expect(intAt(placed, Keys.key(track2Item, Constants.pSeqStepActive, 1, 1, 5)) == 0)
        #expect(!changed(base, placed).keys.contains { $0.contains("_48_") })
    }

    @Test func theReaderSeesAPlacedNote() throws {
        let base = try Samples.raw("baseline.KeyStepPro")
        let placed = try Mutate.placeNote(
            base, track: 2, pattern: 1, step: 5, pitch: 61, velocity: 90)

        let pattern = try Reader.readProject(placed).track(2).pattern(1)
        let notes = pattern.notes(of: .seq)
        #expect(notes.count == 1)
        #expect(notes.first?.step == 5)
        #expect(notes.first?.pitch == 61)
        #expect(notes.first?.velocity == 90)
        #expect(notes.first?.active == true)
    }
}

@Suite struct SetPitchTests {
    /// project_5 Track 3 note 5 is C#2, hardware-confirmed. Move it an octave.
    @Test func setPitchChangesExactlyOneLine() throws {
        let base = try Samples.raw("project_5.KeyStepPro")
        let target = try Mutate.pitchKey(track: 3, pattern: 1, note: 5)
        #expect(intAt(base, target) == 49)

        let edited = try Mutate.setPitch(base, track: 3, pattern: 1, note: 5, pitch: 61)
        #expect(same(changed(base, edited), [target: (49, 61)]))
    }

    /// Ordinals 6-8 share pitch 49, so an off-by-one would show here.
    @Test func setPitchLeavesItsNeighboursAlone() throws {
        let edited = try Mutate.setPitch(
            Samples.raw("project_5.KeyStepPro"), track: 3, pattern: 1, note: 5, pitch: 61)
        let pitches = (4...8).map {
            intAt(edited, Keys.key(track3Item, Constants.pSeqPitch, 1, 1, $0))
        }
        #expect(pitches == [48, 61, 49, 49, 49])
    }

    @Test func theReaderSeesTheNewPitch() throws {
        let edited = try Mutate.setPitch(
            Samples.raw("project_5.KeyStepPro"), track: 3, pattern: 1, note: 5, pitch: 61)
        let notes = try Reader.readProject(edited).track(3).pattern(1).notes(of: .seq)

        #expect(Array(notes.prefix(8).map(\.pitch)) == [48, 48, 48, 48, 61, 49, 49, 49])
        #expect(notes[4].step == 5)
        #expect(notes[4].velocity == 60)
        #expect(notes[4].active)
    }

    @Test func pitchKeyAddressesTheDocumentedKey() throws {
        #expect(try Mutate.pitchKey(track: 3, pattern: 1, note: 5) == "125_109_1_1_5")
    }
}

@Suite struct MutateKeySetTests {
    @Test(arguments: ["place", "pitch"])
    func mutationNeverAddsOrRemovesAKey(_ operation: String) throws {
        let base = try Samples.raw("project_5.KeyStepPro")
        let after =
            operation == "place"
            ? try Mutate.placeNote(base, track: 2, pattern: 1, step: 1, pitch: 60)
            : try Mutate.setPitch(base, track: 3, pattern: 1, note: 5, pitch: 61)
        #expect(Set(after.keys) == Set(base.keys))
    }

    @Test func mutationLeavesTheSourceUntouched() throws {
        let base = try Samples.raw("project_5.KeyStepPro")
        let target = try Mutate.pitchKey(track: 3, pattern: 1, note: 5)
        _ = try Mutate.setPitch(base, track: 3, pattern: 1, note: 5, pitch: 61)
        #expect(intAt(base, target) == 49)
    }
}

@Suite struct MutateRefusalTests {
    @Test func setPitchRefusesANoteThatIsNotInThePool() throws {
        let base = try Samples.raw("project_5.KeyStepPro")
        #expect(intAt(base, "124_50_16_1_1") == Constants.sentinel)

        let thrown = #expect(throws: KSPError.self) {
            try Mutate.setPitch(base, track: 2, pattern: 16, note: 1, pitch: 60)
        }
        #expect(thrown?.description.contains("no note at ordinal") == true)
    }

    /// Zero-filled phantom; capture D2-chord4-tr1 put a 4th voice in slot 1.
    @Test func placeNoteRefusesTrack1Slot4() throws {
        let thrown = #expect(throws: KSPError.self) {
            try Mutate.placeNote(
                Samples.raw("baseline.KeyStepPro"), track: 1, pattern: 1, step: 1, pitch: 60,
                slot: 4)
        }
        #expect(thrown?.description.contains("phantom") == true)
    }

    @Test(
        arguments: [
            (5, 1, 1, 60, 100, 49, 1, "track 5"),
            (2, 17, 1, 60, 100, 49, 1, "pattern 17"),
            (2, 1, 65, 60, 100, 49, 1, "step 65"),
            (2, 1, 1, 128, 100, 49, 1, "pitch 128"),
            (2, 1, 1, -1, 100, 49, 1, "pitch -1"),
            (2, 1, 1, 60, 128, 49, 1, "velocity 128"),
            (2, 1, 1, 60, 100, 49, 4, "slot 4"),
            // Narrower than the 7-bit field the other values allow.
            (2, 1, 1, 60, 100, 100, 1, "time shift 100"),
            (2, 1, 1, 60, 100, -1, 1, "time shift -1"),
        ])
    func placeNoteRefusesOutOfRange(_ testCase: (Int, Int, Int, Int, Int, Int, Int, String)) throws
    {
        let (track, pattern, step, pitch, velocity, shift, slot, match) = testCase
        let base = try Samples.raw("baseline.KeyStepPro")
        let thrown = #expect(throws: KSPError.self) {
            try Mutate.placeNote(
                base, track: track, pattern: pattern, step: step, pitch: pitch,
                velocity: velocity, timeShift: shift, slot: slot)
        }
        #expect(thrown?.description.contains(match) == true)
    }

    @Test(arguments: [0, 99])
    func placeNoteAcceptsBothTimeShiftExtremes(_ stored: Int) throws {
        let raw = try Mutate.placeNote(
            Samples.raw("baseline.KeyStepPro"), track: 2, pattern: 1, step: 1, pitch: 60,
            timeShift: stored)
        #expect(intAt(raw, "124_\(Constants.pSeqTimeShift)_1_1_1") == stored)
    }

    @Test func placeNoteRefusesASeventeenthNoteOnOneStep() throws {
        var project = try Samples.raw("baseline.KeyStepPro")
        for _ in 0..<Constants.maxNotesPerStep {
            project = try Mutate.placeNote(project, track: 2, pattern: 1, step: 1, pitch: 60)
        }
        let full = project
        let thrown = #expect(throws: KSPError.self) {
            try Mutate.placeNote(full, track: 2, pattern: 1, step: 1, pitch: 60)
        }
        #expect(thrown?.description.contains("per-step limit") == true)
    }

    /// `idx2` chunks one flat pool of 3 x 64, so the 65th note is slot 2 ordinal 1, not an error.
    @Test func aFullSlotSpillsIntoTheNextChunk() throws {
        var project = try Samples.raw("baseline.KeyStepPro")
        for step in 1...Constants.maxSteps {
            project = try Mutate.placeNote(project, track: 2, pattern: 1, step: step, pitch: 60)
        }
        project = try Mutate.placeNote(project, track: 2, pattern: 1, step: 1, pitch: 72)

        #expect(intAt(project, "124_\(Constants.pSeqNoteStep)_1_2_1") == 0)
        #expect(intAt(project, "124_\(Constants.pSeqPitch)_1_2_1") == 72)
    }

    @Test func placeNoteRefusesAFullSlotItWasToldToUse() throws {
        var project = try Samples.raw("baseline.KeyStepPro")
        for step in 1...Constants.maxSteps {
            project = try Mutate.placeNote(project, track: 2, pattern: 1, step: step, pitch: 60)
        }
        let full = project
        let thrown = #expect(throws: KSPError.self) {
            try Mutate.placeNote(full, track: 2, pattern: 1, step: 1, pitch: 60, slot: 1)
        }
        #expect(thrown?.description.contains("is full") == true)
    }

    @Test func placeNoteRefusesTheHundredAndNinetyThirdEvent() throws {
        var project = try Samples.raw("baseline.KeyStepPro")
        for index in 0..<Constants.poolCapacity {
            let step = index % Constants.maxSteps + 1
            project = try Mutate.placeNote(project, track: 2, pattern: 1, step: step, pitch: 60)
        }
        let full = project
        let thrown = #expect(throws: KSPError.self) {
            try Mutate.placeNote(full, track: 2, pattern: 1, step: 1, pitch: 60)
        }
        #expect(thrown?.description.contains("per-pattern limit") == true)
    }

    @Test func aBadAddressIsAKeyError() {
        let thrown = #expect(throws: KSPError.self) {
            try Mutate.setPitch(
                ["125_50_1_1_1": .int(0)], track: 3, pattern: 1, note: 1, pitch: 61)
        }
        #expect(thrown == .key("not in the file: 125_109_1_1_1"))
    }
}

@Suite struct MutateDrumAndScalarTests {
    /// Only four keys move: the template already carries a fresh note's gate, velocity and shift.
    private static let drumPlacement: [String: (before: Int?, after: Int)] = [
        "123_40_1": (0, 3),
        "123_52_1_1_21": (0, 16),
        "123_54_1_1_1": (127, 4),
        "123_117_1_1_1": (60, 2),
    ]

    /// `117` holds a lane index where melodic `109` holds a pitch, and `52` is addressed by lane.
    @Test func placingADrumHitWritesTheDrumSet() throws {
        let base = try Samples.raw("Default.KeyStepPro")
        let result = try Mutate.placeDrumNote(base, pattern: 1, lane: 2, step: 5)
        #expect(same(changed(base, result), Self.drumPlacement))
    }

    /// Two hits on one lane share an entry, so the second must not clear the first.
    @Test func theDrumStepActiveBitIsPackedSevenToAnEntry() throws {
        var project = try Samples.raw("Default.KeyStepPro")
        project = try Mutate.placeDrumNote(project, pattern: 1, lane: 0, step: 1)
        project = try Mutate.placeDrumNote(project, pattern: 1, lane: 0, step: 5)
        #expect(intAt(project, "123_52_1_1_1") == 0b1_0001)
    }

    @Test func aDrumHitRefusesALaneTheDeviceDoesNotHave() throws {
        let base = try Samples.raw("Default.KeyStepPro")
        let thrown = #expect(throws: KSPError.self) {
            try Mutate.placeDrumNote(
                base, pattern: 1, lane: Constants.drumLaneCount, step: 1)
        }
        #expect(thrown?.description.contains("drum lane") == true)
    }

    @Test func stepCountIsStoredZeroBased() throws {
        let base = try Samples.raw("Default.KeyStepPro")
        #expect(
            try intAt(Mutate.setStepCount(base, track: 2, pattern: 1, steps: 48), "124_98_1") == 47)
        #expect(
            try intAt(
                Mutate.setStepCount(base, track: 1, pattern: 1, steps: 64, drum: true),
                "123_115_1") == 63)
    }

    /// 50% is straight and stores 25; the device's range tops out at 75%.
    @Test func swingIsStoredWithItsOffset() throws {
        let base = try Samples.raw("Default.KeyStepPro")
        #expect(
            try intAt(Mutate.setSwing(base, track: 2, pattern: 1, percent: 50), "124_97_1") == 25)
        #expect(
            try intAt(Mutate.setSwing(base, track: 2, pattern: 1, percent: 75), "124_97_1") == 50)
        let thrown = #expect(throws: KSPError.self) {
            try Mutate.setSwing(base, track: 2, pattern: 1, percent: 76)
        }
        #expect(thrown?.description.contains("out of range") == true)
    }

    @Test func drumModeMovesBitSixAndNothingElse() throws {
        let base = try Samples.raw("Default.KeyStepPro")
        let before = try #require(intAt(base, "123_86"))

        let on = try Mutate.setDrumMode(base, track: 1, on: true)
        #expect(intAt(on, "123_86") == before | 1 << Constants.drumModeBit)
        #expect(try intAt(Mutate.setDrumMode(on, track: 1, on: false), "123_86") == before)
    }

    /// Bit 6 is ARP on tracks 2-4, so setting it there selects notes we did not write (spec 5).
    @Test func drumModeIsRefusedOnATrackWithNoDrumSet() throws {
        let base = try Samples.raw("Default.KeyStepPro")
        let thrown = #expect(throws: KSPError.self) {
            try Mutate.setDrumMode(base, track: 2, on: true)
        }
        #expect(thrown?.description.contains("no drum parameter set") == true)
    }

    /// project_5 stores 120 BPM as 96, 93, 0 -- the encoding this inverts.
    @Test func tempoRoundTripsThroughItsThreeChunks() throws {
        let result = try Mutate.setTempo(Samples.raw("Default.KeyStepPro"), bpm: 120)
        #expect(intAt(result, "120_70") == 96)
        #expect(intAt(result, "120_71") == 93)
        #expect(intAt(result, "120_72") == 0)
        #expect(try Reader.readProject(result, sourceName: "tempo").tempoBPM == 120.0)
    }

    /// Capture T5-chain-3's shape: patterns in order, then 127 to the end.
    @Test func aChainIsZeroBasedAndSentinelFilled() throws {
        let result = try Mutate.setChain(
            Samples.raw("Default.KeyStepPro"), scene: 1, track: 4, patterns: [1, 2])
        let stored = (1...Constants.chainSlots).map { intAt(result, "121_84_1_4_\($0)") }
        #expect(stored == [0, 1] + Array(repeating: Constants.sentinel, count: 14))
    }
}
