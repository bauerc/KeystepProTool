import Testing

@testable import KSPKit

@Suite struct DrumMapTests {
    @Test func theDeviceHasTwentyFourLanes() {
        // From MCC's Drum Map group, which defines Note 1..Note 24; no project file says so.
        #expect(Constants.drumLaneCount == 24)
    }

    @Test func theDefaultMatchesArturiasCustomNoteDefaults() throws {
        // KeyStepPro.json gives Note 1..Note 24 defaults of 36..59, and the device agrees.
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
        let notes = (0..<Constants.drumLaneCount).map { (37 * $0 + 5) % 128 }
        let drumMap = try DrumMap.custom(notes)
        #expect(try drumMap.laneForNote(drumMap.noteForLane(lane)) == lane)
    }

    @Test func anUnmappedNoteIsNilRatherThanANearestLaneGuess() throws {
        // Snapping to the closest lane would load cleanly and play the wrong instrument.
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
        // 103 + 23 = 126: the gap to 127 is Arturia's range, not an off-by-one here.
        #expect(try DrumMap.chromatic(103).notes.last == 126)
    }

    @Test func aLabelNamesTheGMInstrument() throws {
        #expect(try DrumMap.chromatic(36).labelForLane(0) == "lane 0 -> C1 (36) Bass Drum 1")
    }

    @Test func aLabelWithoutAGMNameStillRenders() throws {
        #expect(try DrumMap.chromatic(0).labelForLane(0) == "lane 0 -> C-2 (0)")
    }

    @Test func aLaneTheDeviceLacksIsNotResolved() throws {
        #expect(try DrumMap.chromatic().labelForLane(60).contains("out of range"))
    }

    @Test func describeSaysItIsAnAssumption() throws {
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
