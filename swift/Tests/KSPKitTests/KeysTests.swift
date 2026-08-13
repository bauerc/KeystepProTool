import Testing

@testable import KSPKit

/// Twin of `TestKeys` in `tests/test_reader.py`, plus the lookups that file exercises through
/// the reader: absent is not an error, and a value of the wrong type is.
@Suite struct KeysTests {
    @Test func keyBuildsTheGrammar() {
        #expect(Keys.key(125, 109, 1, 1, 10) == "125_109_1_1_10")
        #expect(Keys.key(120, 74) == "120_74")
    }

    @Test func keyTakesMoreIndicesThanTheGrammarUses() {
        // Three is all the format needs; nothing should break if a caller passes more.
        #expect(Keys.key(123, 52, 1, 2, 3, 4) == "123_52_1_2_3_4")
    }

    @Test func readArrayIsZeroBasedOverOneBasedKeys() throws {
        let raw: RawProject = ["125_50_1_1_1": .int(0), "125_50_1_1_2": .int(4)]
        #expect(try Keys.readArray(raw, 125, 50, 1, 1, length: 3) == [0, 4, nil])
    }

    @Test func readArrayRefusesANonInteger() {
        let raw: RawProject = ["125_50_1_1_1": .string("x")]
        let thrown = #expect(throws: KSPError.self) {
            try Keys.readArray(raw, 125, 50, 1, 1, length: 1)
        }
        #expect(thrown == .type("125_50_1_1_1 holds str, expected int"))
    }

    @Test func getIntReadsOneValue() throws {
        let raw: RawProject = ["120_70": .int(96)]
        #expect(try Keys.getInt(raw, 120, 70) == 96)
    }

    @Test func anAbsentKeyIsNilRatherThanAnError() throws {
        // The key set differs between item types -- only item 123 carries drum parameters -- so
        // callers probing a parameter that may not apply get nothing back, not a failure.
        #expect(try Keys.getInt([:], 124, Constants.pDrumPitch, 1, 1) == nil)
    }

    @Test func getIntRefusesANonInteger() {
        // A file whose shape differs from every sample we have, which is worth surfacing loudly
        // rather than silently coercing.
        let raw: RawProject = ["120_70": .string("96")]
        let thrown = #expect(throws: KSPError.self) { try Keys.getInt(raw, 120, 70) }
        #expect(thrown == .type("120_70 holds str, expected int"))
    }

    @Test(arguments: [(1, 123), (2, 124), (3, 125), (4, 126)])
    func itemForTrackNamesTheSequencerItems(track: Int, item: Int) throws {
        #expect(try Keys.itemForTrack(track) == item)
    }

    @Test(arguments: [0, 5, -1])
    func aTrackOutsideTheDevicesFourIsRefused(track: Int) {
        let thrown = #expect(throws: KSPError.self) { try Keys.itemForTrack(track) }
        #expect(thrown == .value("track \(track) out of range 1-4"))
    }
}
