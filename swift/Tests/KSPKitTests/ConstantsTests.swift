import Foundation
import Testing

@testable import KSPKit

/// Stored value -> gate length, known independently of the transcription: six from the sample
/// projects, stored 36 from capture D25-gate-capture. A ladder shifted by a detent would still
/// look self-consistent, but would not reproduce these.
private let crossCheckPoints = [
    (7, 0.5), (11, 1.0), (19, 2.0), (27, 3.0), (29, 3.5), (31, 4.0), (36, 5.25),
]

/// Twins of `tests/test_gate_ladder.py`, checked against the same transcription.
///
/// `gateTable` enumerates 128 entries from five run lengths rather than listing them, so these
/// check that rule reproduces every transcribed row. The file holds the device's 2-decimal
/// rendering, so the comparison rounds the exact binary fraction the same way -- half to even,
/// as Python's `round` does, which is why 0.625 shows as 0.62.
@Suite struct GateLadderTests {
    struct Rung {
        let display: String
        let provenance: String
    }

    let ladder: [Rung]

    init() throws {
        let data = try Data(contentsOf: RepoData.analysis.appending(path: "gate_ladder.txt"))
        ladder = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            return Rung(display: String(fields[0]), provenance: String(fields[1]))
        }
    }

    @Test func theLadderCoversEveryLegalStoredValue() {
        // A hole would silently become a default gate.
        #expect(Constants.gateTable.count == 128)
    }

    @Test func theLadderSpansTheEncoderRange() {
        // The exact closure on 127 count-verifies the enumerated upper detents.
        #expect(Constants.gateTable[0] == 0.0625)
        #expect(Constants.gateTable[127] == 64.0)
        #expect(ladder.count == 128)
    }

    @Test func theLadderIsStrictlyIncreasing() {
        #expect(zip(Constants.gateTable, Constants.gateTable.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func everyTranscribedDetentMatchesTheTable() {
        // The whole point: stored = detent index - 1, for all 128 rungs.
        let mismatches = ladder.indices.filter { stored in
            let rounded = (Constants.gateTable[stored] * 100).rounded(.toNearestOrEven) / 100
            return rounded != Double(ladder[stored].display)
        }
        #expect(mismatches.isEmpty)
    }

    @Test(arguments: crossCheckPoints)
    func theCrossCheckPointsHold(stored: Int, expected: Double) {
        #expect(Constants.gateTable[stored] == expected)
    }

    @Test func noRungIsStillDerived() {
        // Every rung is read off the device or enumerated from the increment rule;
        // D25-gate-capture closed the last derived one.
        #expect(Set(ladder.map(\.provenance)) == ["measured", "enumerated"])
    }

    @Test func theCrossCheckPointsAreAllMeasured() {
        // A cross-check point resting on an enumerated rung would be circular.
        #expect(crossCheckPoints.allSatisfy { ladder[$0.0].provenance == "measured" })
    }
}

/// Twins of the encoding cases in `tests/test_reader.py` and `tests/test_timing_baseline.py`.
@Suite struct EncodingTests {
    @Test(arguments: [(7, 0.5), (11, 1.0), (19, 2.0), (27, 3.0), (29, 3.5), (31, 4.0)])
    func knownGateValuesDecode(stored: Int, expected: Double) {
        #expect(Constants.decodeGate(stored) == expected)
    }

    /// One value from each of the five display runs, plus both extremes.
    @Test(arguments: [
        (0, 0.0625), (2, 0.1875), (8, 0.625), (15, 1.5), (28, 3.25), (48, 8.5), (127, 64.0),
    ])
    func theRestOfTheLadderDecodes(stored: Int, expected: Double) {
        #expect(Constants.decodeGate(stored) == expected)
    }

    /// The ladder covers every legal 7-bit value, so anything outside it is corrupt input.
    /// Rounding it to the nearest rung would produce a file that loads cleanly and plays wrong.
    @Test(arguments: [-1, 128, 255])
    func aGateOffTheLadderIsNotGuessed(stored: Int) {
        #expect(Constants.decodeGate(stored) == nil)
    }

    @Test func encodeGateTakesTheNearestRung() {
        #expect(Constants.encodeGate(0.5) == 7)
        #expect(Constants.encodeGate(64.0) == 127)
        // Above 3 steps the ladder is coarse, so an arbitrary duration lands between rungs.
        #expect(Constants.encodeGate(8.2) == 47)
        #expect(Constants.encodeGate(8.4) == 48)
        // Past the top rung the nearest is the top rung; nothing extrapolates.
        #expect(Constants.encodeGate(1000.0) == 127)
    }

    @Test func encodeGateBreaksATieOnTheLowerRung() {
        // Python takes min() over (distance, stored); the same order holds here.
        #expect(Constants.encodeGate(0.09375) == 0)
    }

    @Test(arguments: [
        (15, [16, 32, 48, 64]), (0, []), (1, [16]), (2, [32]), (5, [16, 48]), (10, [32, 64]),
        (12, [48, 64]), (3, [16, 32]),
    ])
    func skipMaskDecodes(mask: Int, expected: [Int]) {
        #expect(Constants.decodeSkipMask(mask) == expected)
    }

    @Test func theDefaultSkipMaskIsEverySequence() {
        #expect(Constants.skipMaskAll == 15)
        #expect(Constants.decodeSkipMask(Constants.skipMaskAll).count == Constants.skipCyclePasses)
    }

    /// 48 displays as C2 and 60 as C3, per the two ground truth documents.
    @Test(arguments: [(48, "C2"), (49, "C#2"), (50, "D2"), (60, "C3"), (72, "C4")])
    func noteNamesUseTheHardwareOctaveConvention(pitch: Int, name: String) {
        #expect(Constants.noteName(pitch) == name)
    }

    @Test func noteNamesFloorBelowTheOrigin() {
        // Python's // floors and its % is never negative; Swift's / and % truncate, so a pitch
        // under 0 is where a translated-by-eye port stops agreeing.
        #expect(Constants.noteName(0) == "C-2")
        #expect(Constants.noteName(-1) == "B-3")
        #expect(Constants.rootNoteName(-1) == "B")
    }

    @Test(arguments: [(0, "Chromatic"), (2, "Minor"), (7, "Root"), (9, "User 2")])
    func scaleNamesFollowTheDeviceList(stored: Int, name: String) {
        #expect(Constants.scaleName(stored) == name)
    }

    @Test(arguments: [-1, 10, 127])
    func aScaleOffTheListIsNotNamed(stored: Int) {
        #expect(Constants.scaleName(stored) == nil)
    }

    @Test func rootNotesAreNamedWithoutAnOctave() {
        #expect(Constants.rootNoteName(2) == "D")
        #expect(Constants.rootNoteName(11) == "B")
    }

    /// R1/R6 at 480 ticks per beat, the resolution the recordings were made at.
    @Test(arguments: [(0, 0), (1, 1), (25, 30), (50, 60), (-1, -1), (-25, -30), (-49, -59)])
    func theShiftUnitMatchesTheRecordings(shift: Int, ticks: Int) {
        #expect(Constants.timeShiftTicks(shift, ticksPerBeat: 480) == ticks)
    }

    @Test func theShiftUnitScalesWithTheResolution() {
        // It is a fraction of a beat, so a finer PPQ buys proportionally more.
        #expect(Constants.timeShiftTicks(50, ticksPerBeat: 960) == 120)
        #expect(Constants.timeShiftTicks(-49, ticksPerBeat: 960) == -118)
    }

    @Test func theShiftRoundsHalvesToEven() {
        // No standard PPQ produces a tie, but Python's round() breaks one to even and Swift's
        // rounded() breaks it away from zero. Pinned so the port cannot drift on a PPQ that does.
        #expect(Constants.timeShiftTicks(1, ticksPerBeat: 1000) == 2)
        #expect(Constants.timeShiftTicks(3, ticksPerBeat: 200) == 2)
    }

    @Test func theStoredShiftBoundsSitEitherSideOfTheCentre() {
        #expect(Constants.timeShiftCentre == 49)
        #expect(Constants.timeShiftStoredMin == 0)
        #expect(Constants.timeShiftStoredMax == 99)
    }
}

/// One row of tier 5's pattern-bits sweep: a stored value and what the device displayed for it.
struct MeasuredBits: Sendable {
    let raw: Int
    let denominator: Int
    let triplet: Bool
    let direction: Int
}

/// Every value tier 5 produced, on both halves of the field.
private let measuredBits = [
    MeasuredBits(raw: 4, denominator: 4, triplet: false, direction: Constants.directionForward),
    MeasuredBits(raw: 12, denominator: 8, triplet: false, direction: Constants.directionForward),
    MeasuredBits(raw: 20, denominator: 16, triplet: false, direction: Constants.directionForward),
    MeasuredBits(raw: 28, denominator: 32, triplet: false, direction: Constants.directionForward),
    MeasuredBits(raw: 5, denominator: 4, triplet: true, direction: Constants.directionForward),
    MeasuredBits(raw: 13, denominator: 8, triplet: true, direction: Constants.directionForward),
    MeasuredBits(raw: 21, denominator: 16, triplet: true, direction: Constants.directionForward),
    MeasuredBits(raw: 29, denominator: 32, triplet: true, direction: Constants.directionForward),
    MeasuredBits(raw: 52, denominator: 16, triplet: false, direction: Constants.directionRandom),
    MeasuredBits(raw: 84, denominator: 16, triplet: false, direction: Constants.directionWalk),
    MeasuredBits(raw: 16, denominator: 16, triplet: false, direction: Constants.directionForward),
    MeasuredBits(raw: 0, denominator: 4, triplet: false, direction: Constants.directionForward),
    MeasuredBits(raw: 8, denominator: 8, triplet: false, direction: Constants.directionForward),
    MeasuredBits(raw: 24, denominator: 32, triplet: false, direction: Constants.directionForward),
]

/// Twin of `tests/test_pattern_bits.py`, at the level M9 reaches: the model's `PatternBits`
/// wrapper is M10, so these assert on the constants that decode is built from.
@Suite struct PatternBitsTests {
    @Test(arguments: measuredBits)
    func everyMeasuredValueDecodesToWhatTheDeviceDisplayed(bits: MeasuredBits) {
        #expect(Constants.stepDenominator(bits.raw) == bits.denominator)
        #expect(Constants.isTriplet(bits.raw) == bits.triplet)
        #expect(Constants.directionIndex(bits.raw) == bits.direction)
        #expect(Constants.unallocatedBits(bits.raw) == 0)
    }

    @Test func theFieldsDoNotOverlap() {
        var covered = 0
        for (shift, mask) in [
            (Constants.tripletBit, 1), (Constants.polyrhythmBit, 1),
            (Constants.stepSizeShift, Constants.stepSizeMask),
            (Constants.directionShift, Constants.directionMask),
        ] {
            let field = mask << shift
            #expect(covered & field == 0)
            covered |= field
        }
        // Seven bits, one of which nothing has ever set.
        #expect(covered == 0b111_1101)
    }

    @Test func theTwoDefaultsDifferOnlyByPolyrhythm() {
        // 20 on the sequencer half, 16 on the drum half (spec 3.3).
        #expect(Constants.isPolyrhythm(20))
        #expect(!Constants.isPolyrhythm(16))
        #expect(Constants.stepDenominator(20) == Constants.stepDenominator(16))
        #expect(Constants.isTriplet(20) == Constants.isTriplet(16))
        #expect(Constants.directionIndex(20) == Constants.directionIndex(16))
    }

    @Test func theFourthDirectionIsStillDecoded() {
        // Two bits allow it; the device never produced it, so M10 gives it no name.
        #expect(Constants.directionIndex(20 | 3 << Constants.directionShift) == 3)
    }

    @Test func theUnallocatedBitIsSurfacedNotAbsorbed() {
        #expect(Constants.unallocatedBits(20 | 0b10) == 0b10)
        // And nothing else in the decode is disturbed by it.
        #expect(Constants.stepDenominator(20 | 0b10) == 16)
        #expect(Constants.directionIndex(20 | 0b10) == Constants.directionForward)
    }

    @Test func settingTheStepSizeLeavesTheOtherFieldsAlone() throws {
        // What `mutate.set_step_size` relies on when writing into a template.
        let tripletWalk = 21 | 2 << Constants.directionShift
        let updated = try Constants.stepsPerBeatBits(tripletWalk, stepsPerBeat: 8)

        #expect(Constants.stepDenominator(updated) == 32)
        #expect(Constants.isTriplet(updated) == Constants.isTriplet(tripletWalk))
        #expect(Constants.isPolyrhythm(updated) == Constants.isPolyrhythm(tripletWalk))
        #expect(Constants.directionIndex(updated) == Constants.directionIndex(tripletWalk))
    }

    @Test func aStepSizeTheDeviceCannotHoldIsRefused() {
        // The field is two bits wide: 1/4 to 1/32 and nothing else.
        let thrown = #expect(throws: KSPError.self) {
            try Constants.stepsPerBeatBits(20, stepsPerBeat: 3)
        }
        #expect(thrown?.description.contains("1/12 steps cannot be stored") == true)
    }

    @Test func aStepsPerBeatBelowOneIsRefused() {
        let thrown = #expect(throws: KSPError.self) { try Constants.checkStepsPerBeat(0) }
        #expect(thrown?.description == "steps_per_beat must be at least 1")
    }
}

/// One case of the parameter 52 packing: where a lane's step bit lives in the file.
struct StepActiveCase: Sendable {
    let lane: Int
    let step: Int
    let slot: Int
    let index: Int
    let bit: Int
}

private let stepActiveCases = [
    // Lane 0 starts at flat 0, so its first entry is i2=1, i3=1.
    StepActiveCase(lane: 0, step: 0, slot: 1, index: 1, bit: 0),
    StepActiveCase(lane: 0, step: 4, slot: 1, index: 1, bit: 4),
    StepActiveCase(lane: 0, step: 6, slot: 1, index: 1, bit: 6),
    // Step 7 rolls into the lane's second part, not a second bit-width.
    StepActiveCase(lane: 0, step: 7, slot: 1, index: 2, bit: 0),
    StepActiveCase(lane: 0, step: 63, slot: 1, index: 10, bit: 0),
    // Lane 1 begins 10 entries later.
    StepActiveCase(lane: 1, step: 0, slot: 1, index: 11, bit: 0),
    // Lane 6 sits at flat 60..69, which straddles the 64-entry chunk edge.
    StepActiveCase(lane: 6, step: 27, slot: 1, index: 64, bit: 6),
    StepActiveCase(lane: 6, step: 28, slot: 2, index: 1, bit: 0),
    // The last lane stays inside the four chunks the file provides.
    StepActiveCase(lane: 23, step: 63, slot: 4, index: 48, bit: 0),
]

/// Twin of the parameter 52 packing cases in `tests/test_step_active.py`.
///
/// Flattened [lane][part], lane-major, 7 bits per entry, 10 entries per lane.
@Suite struct DrumStepActiveTests {
    @Test(arguments: stepActiveCases)
    func drumStepActiveIndices(expected: StepActiveCase) {
        let located = Constants.drumStepActiveIndices(lane: expected.lane, step: expected.step)
        #expect(located.slot == expected.slot)
        #expect(located.index == expected.index)
        #expect(located.bit == expected.bit)
    }

    @Test func drumStepActiveIndicesAreUnique() {
        // No two (lane, step) pairs may share a bit, or flags would collide.
        var seen: Set<[Int]> = []
        for lane in 0..<Constants.drumLaneCount {
            for step in 0..<Constants.maxSteps {
                let located = Constants.drumStepActiveIndices(lane: lane, step: step)
                seen.insert([located.slot, located.index, located.bit])
            }
        }
        #expect(seen.count == Constants.drumLaneCount * Constants.maxSteps)
    }

    @Test func drumStepActiveStaysWithinTheFileArrays() throws {
        // Every bit must land in an index the file actually has.
        let slots = try #require(Constants.slotsByItem[Constants.drumTrackItemID])
        for lane in 0..<Constants.drumLaneCount {
            for step in 0..<Constants.maxSteps {
                let located = Constants.drumStepActiveIndices(lane: lane, step: step)
                #expect((1...slots).contains(located.slot))
                #expect((1...Constants.maxSteps).contains(located.index))
                #expect((0..<Constants.drumStepActiveBitsPerEntry).contains(located.bit))
            }
        }
    }
}
