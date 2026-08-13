import Testing

@testable import KSPKit

/// Twin of `tests/test_drum_map.py`, minus the `--drum-map` spec parsing, which lives in the CLI
/// on both sides.
///
/// The map is a *device global setting* that no project file contains, so these tests pin two
/// separate things: that the built-in default matches what Arturia documents, and that the port
/// never invents a mapping it does not have.
@Suite struct DrumMapTests {
    @Test func theDeviceHasTwentyFourLanes() {
        // Derived, not assumed: MCC's Drum Map group defines Note 1..Note 24. Nothing in the
        // project file has this cardinality -- the lane is a value of parameter 117, never an
        // index -- so the constant has to come from the parameter dictionary.
        #expect(Constants.drumLaneCount == 24)
    }

    @Test func theDefaultMatchesArturiasCustomNoteDefaults() throws {
        // KeyStepPro.json gives Note 1..Note 24 defaults of 36..59, and the manual says "the
        // default mapping starts at MIDI note 36". The device transmits that same run (D5).
        #expect(try DrumMap.chromatic().notes == Array(36..<60))
    }

    @Test func theDefaultLowNoteIsTheGMKick() {
        #expect(DrumMap.defaultChromaticLow == 36)
        #expect(DrumMap.gmDrumNames[36] == "Bass Drum 1")
    }

    @Test func theDrumChannelDefaultIsTen() {
        // globalParamId 79 (Drum output) defaults to 10, unlike tracks 1-4.
        #expect(DrumMap.defaultDrumChannel == 10)
    }

    @Test(arguments: 0..<Constants.drumLaneCount)
    func chromaticRoundTrips(lane: Int) throws {
        let drumMap = try DrumMap.chromatic()
        #expect(try drumMap.laneForNote(drumMap.noteForLane(lane)) == lane)
    }

    @Test(arguments: 0..<Constants.drumLaneCount)
    func aScrambledCustomMapRoundTrips(lane: Int) throws {
        // Or reverse lookup is order-dependent.
        let notes = (0..<Constants.drumLaneCount).map { (37 * $0 + 5) % 128 }
        let drumMap = try DrumMap.custom(notes)
        #expect(try drumMap.laneForNote(drumMap.noteForLane(lane)) == lane)
    }

    @Test func anUnmappedNoteIsNilRatherThanANearestLaneGuess() throws {
        // Snapping an unmapped drum hit to the closest lane produces a file that loads cleanly
        // and plays the wrong instrument, with nothing to signal the error.
        #expect(try DrumMap.chromatic(36).laneForNote(100) == nil)
        #expect(try DrumMap.chromatic(36).laneForNote(35) == nil)
    }

    @Test func duplicateNotesWarnAndResolveToTheLowestLane() throws {
        let notes = [36, 36] + Array(38..<(38 + Constants.drumLaneCount - 2))
        let drumMap = try DrumMap.custom(notes)
        #expect(drumMap.laneForNote(36) == 0)
        #expect(drumMap.warnings.first?.contains("lowest") == true)
    }

    @Test func aLaneOutsideTheDeviceIsRejected() throws {
        let drumMap = try DrumMap.chromatic()
        #expect(!drumMap.hasLane(Constants.drumLaneCount))
        let thrown = #expect(throws: KSPError.self) {
            try drumMap.noteForLane(Constants.drumLaneCount)
        }
        #expect(thrown?.description.contains("outside") == true)
    }

    @Test(arguments: [0, 23, 25]) func aMapOfTheWrongLengthIsRejected(count: Int) {
        let thrown = #expect(throws: KSPError.self) {
            try DrumMap.custom(Array(repeating: 36, count: count))
        }
        #expect(thrown?.description.contains("exactly 24") == true)
    }

    @Test(arguments: [-1, 128]) func aNoteOutsideTheMIDIRangeIsRejected(note: Int) {
        let notes = [note] + Array(repeating: 40, count: Constants.drumLaneCount - 1)
        let thrown = #expect(throws: KSPError.self) { try DrumMap.custom(notes) }
        #expect(thrown?.description.contains("outside 0-127") == true)
    }

    @Test(arguments: [-1, 104, 120]) func aChromaticLowOutsideTheDevicesRangeIsRejected(low: Int) {
        let thrown = #expect(throws: KSPError.self) { try DrumMap.chromatic(low) }
        #expect(thrown?.description.contains("outside 0-103") == true)
    }

    @Test func theDevicesHighestLowNoteStillFits() throws {
        // 103 + 23 = 126, one short of 127. The gap is Arturia's range being one short, not an
        // off-by-one here: D5 heard lane 0 fire 36 with the low note at 36.
        #expect(try DrumMap.chromatic(103).notes.last == 126)
    }

    @Test func aLabelNamesTheGMInstrument() throws {
        #expect(try DrumMap.chromatic(36).labelForLane(0) == "lane 0 -> C1 (36) Bass Drum 1")
    }

    @Test func aLabelWithoutAGMNameStillRenders() throws {
        #expect(try DrumMap.chromatic(0).labelForLane(0) == "lane 0 -> C-2 (0)")
    }

    @Test func aLaneTheDeviceLacksIsNotResolved() throws {
        // Better to show the raw lane than to invent a note for it.
        #expect(try DrumMap.chromatic().labelForLane(60).contains("out of range"))
    }

    @Test func describeSaysItIsAnAssumption() throws {
        // The annotation is load-bearing: this is device state we cannot read.
        #expect(try DrumMap.chromatic(36).describe() == "chromatic from 36 (assumed - not in file)")
        #expect(try DrumMap.custom(Array(36..<60)).describe().contains("assumed"))
    }

    @Test func jsonCarriesTheNameBecauseTheCallerMustPrintIt() throws {
        let node = try DrumMap.chromatic(36).toJSON()
        #expect(
            node
                == .object([
                    ("name", .string("chromatic-36")),
                    ("notes", .array((36..<60).map { .int($0) })), ("warnings", .array([])),
                ]))
    }
}
