import Testing

@testable import KSPKit

@Suite struct ModelTests {
    private func note(
        kind: NoteKind = .seq, slot: Int = 1, index: Int = 1, step: Int = 1, pitch: Int = 60,
        active: Bool = true
    ) -> Note {
        Note(
            kind: kind, slot: slot, index: index, step: step, pitch: pitch, velocity: 100,
            gateRaw: 7, gate: 0.5, timeShift: 0, randomness: 100, skip: [16, 32, 48, 64],
            active: active)
    }

    @Test func patternBitsCarryTheRawValueSoNobodyGoesBackToTheFile() {
        let bits = PatternBits.decode(21)
        #expect(bits.raw == 21)
        #expect(bits.label == "1/16T")
        #expect(bits.stepsPerBeat == 4)
    }

    @Test func stepsPerBeatIsTheDenominatorOverFour() {
        #expect(PatternBits.decode(4).stepsPerBeat == 1)
        #expect(PatternBits.decode(28).stepsPerBeat == 8)
    }

    @Test func theFourthDirectionHasNoName() {
        #expect(PatternBits.decode(20 | 3 << Constants.directionShift).direction == .unknown)
    }

    @Test func aMelodicNoteLabelsItselfWithAPitchName() {
        #expect(note(pitch: 48).label == "C2 (48)")
    }

    @Test func aDrumNoteWithoutAMapCanOnlyGiveItsLane() {
        // Which MIDI note a lane transmits is a device setting the file does not contain.
        #expect(note(kind: .drum, pitch: 0).label == "lane 0")
    }

    @Test func aDrumNoteResolvesThroughAMapWhenGivenOne() throws {
        let labelled = note(kind: .drum, pitch: 0).labelled(try DrumMap.chromatic(36))
        #expect(labelled == "lane 0 -> C1 (36) Bass Drum 1")
    }

    @Test func aPatternSplitsItsNotesByParameterSet() {
        let pattern = Self.pattern(notes: [
            note(kind: .seq, index: 1), note(kind: .drum, index: 1, pitch: 0),
        ])
        #expect(pattern.notes(of: .seq).count == 1)
        #expect(pattern.notes(of: .drum).count == 1)
        #expect(!pattern.isEmpty)
    }

    @Test func aPatternWithoutADrumSetFallsBackToTheMelodicBitfield() {
        // Tracks 2-4 have no drum parameter set at all, so the drum field must not be invented.
        let pattern = Self.pattern(notes: [])
        #expect(pattern.drumBits == nil)
        #expect(pattern.bits(.drum) == pattern.seqBits)
    }

    @Test func selectNarrowsToOneTrackAndPattern() {
        let project = Self.project()
        let narrowed = project.select(tracks: [1], patterns: [2])
        #expect(narrowed.tracks.count == 1)
        #expect(narrowed.tracks[0].patterns.map(\.number) == [2])
        #expect(narrowed.tracks[0].drumMode == project.tracks[0].drumMode)
        #expect(narrowed.tempoBPM == project.tempoBPM)
    }

    @Test func selectWithoutArgumentsKeepsEverything() {
        let project = Self.project()
        #expect(project.select().tracks.count == project.tracks.count)
    }

    private static func sample() throws -> Project { try Samples.project("project_9.KeyStepPro") }

    private static func numbers(_ project: Project) -> [Int] { project.tracks.map(\.number) }

    private static func patterns(_ project: Project, _ track: Int) -> [Int] {
        project.tracks[track].patterns.map(\.number)
    }

    @Test func selectOneTrack() throws {
        #expect(Self.numbers(try Self.sample().select(tracks: [3])) == [3])
    }

    @Test func selectSeveralTracks() throws {
        #expect(Self.numbers(try Self.sample().select(tracks: [1, 3])) == [1, 3])
    }

    @Test func selectAContiguousPatternRange() throws {
        let narrowed = try Self.sample().select(patterns: [2, 3, 4, 5])
        #expect(Self.numbers(narrowed) == [1, 2, 3, 4])  // patterns narrow, tracks do not
        #expect(Self.patterns(narrowed, 0) == [2, 3, 4, 5])
    }

    @Test func selectANonContiguousPatternSet() throws {
        #expect(Self.patterns(try Self.sample().select(patterns: [1, 5, 9]), 0) == [1, 5, 9])
    }

    @Test func anEmptySelectionMeansEverything() throws {
        let project = try Self.sample()
        let narrowed = project.select()
        #expect(Self.numbers(narrowed) == Self.numbers(project))
        #expect(Self.patterns(narrowed, 0) == Self.patterns(project, 0))
    }

    @Test func selectBothSetsAtOnce() throws {
        let narrowed = try Self.sample().select(tracks: [1, 4], patterns: [2])
        #expect(Self.numbers(narrowed) == [1, 4])
        #expect([0, 1].map { Self.patterns(narrowed, $0) } == [[2], [2]])
    }

    /// The cross product's blind spot: a different set of slots on each track.
    @Test func selectCellsKeepsAdifferentPatternSetPerTrack() throws {
        let narrowed = try Self.sample().select(cells: [1: [2, 3], 3: [7]])
        #expect(Self.numbers(narrowed) == [1, 3])
        #expect(Self.patterns(narrowed, 0) == [2, 3])
        #expect(Self.patterns(narrowed, 1) == [7])
    }

    @Test func selectNoCellsMeansEverything() throws {
        let project = try Self.sample()
        let narrowed = project.select(cells: [:])
        #expect(Self.numbers(narrowed) == Self.numbers(project))
        #expect(Self.patterns(narrowed, 0) == Self.patterns(project, 0))
    }

    @Test func selectCellsDropsAtrackItDoesNotName() throws {
        #expect(Self.numbers(try Self.sample().select(cells: [2: [1]])) == [2])
    }

    @Test func selectCellsSurvivesTheFieldsItDoesNotNarrow() throws {
        let project = try Self.sample()
        let narrowed = project.select(cells: [1: [1]])
        #expect(narrowed.tracks[0].drumMode == project.tracks[0].drumMode)
        #expect(narrowed.tracks[0].itemID == project.tracks[0].itemID)
        #expect(narrowed.tempoBPM == project.tempoBPM)
    }

    @Test func selectionKeepsTheProjectOrder() throws {
        // A set has no order; the project's own order is what survives.
        #expect(Self.numbers(try Self.sample().select(tracks: [4, 2, 1])) == [1, 2, 4])
    }

    @Test func aNumberNoTrackHasSelectsNothing() throws {
        // Range checking belongs to the CLI, not here.
        #expect(try Self.sample().select(tracks: [9]).tracks.isEmpty)
    }

    @Test func onlyScenesThatChainSomethingAreReported() {
        let scenes = [
            Scene(number: 1, chains: []),
            Scene(number: 2, chains: [Chain(track: 1, patterns: [1, 2])]),
        ]
        #expect(Self.project(scenes: scenes).chainedScenes.map(\.number) == [2])
    }

    @Test func patternBitsJSONKeepsThePythonKeyOrder() {
        let node = PatternBits.decode(20).toJSON()
        guard case .object(let members) = node else {
            Issue.record("pattern bits should serialise to an object")
            return
        }
        #expect(
            members.map(\.0) == [
                "raw", "step_size", "step_denominator", "triplet", "polyrhythm", "direction",
                "unallocated",
            ])
    }

    @Test func noteJSONKeepsThePythonKeyOrder() {
        guard case .object(let members) = note().toJSON() else {
            Issue.record("a note should serialise to an object")
            return
        }
        #expect(
            members.map(\.0) == [
                "kind", "slot", "index", "step", "pitch", "velocity", "gate_raw", "gate",
                "time_shift", "randomness", "skip", "active",
            ])
    }

    @Test func aResolvedDrumNoteGainsTwoKeysAtTheEnd() throws {
        let node = note(kind: .drum, pitch: 0).toJSON(drumMap: try DrumMap.chromatic(36))
        guard case .object(let members) = node else {
            Issue.record("a note should serialise to an object")
            return
        }
        #expect(members.suffix(2).map(\.0) == ["drum_note", "drum_note_name"])
        #expect(members.suffix(2).map(\.1) == [.int(36), .string("C1")])
    }

    @Test func aLaneTheDeviceLacksIsNotResolvedIntoJSON() throws {
        // The reader warns about an out-of-range lane separately; a note here would hide it.
        let node = note(kind: .drum, pitch: 99).toJSON(drumMap: try DrumMap.chromatic(36))
        guard case .object(let members) = node else {
            Issue.record("a note should serialise to an object")
            return
        }
        #expect(!members.map(\.0).contains("drum_note"))
    }

    @Test func projectJSONKeepsThePythonKeyOrder() {
        guard case .object(let members) = Self.project().toJSON() else {
            Issue.record("a project should serialise to an object")
            return
        }
        #expect(
            members.map(\.0) == [
                "source", "device", "version", "tempo_bpm", "global_swing_percent",
                "current_scene", "scenes", "warnings", "diagnostics", "tracks",
            ])
    }

    @Test func theDrumMapIsNamedAtTheTopLevelJustBeforeTheTracks() throws {
        let node = Self.project().toJSON(drumMap: try DrumMap.chromatic())
        guard case .object(let members) = node else {
            Issue.record("a project should serialise to an object")
            return
        }
        #expect(members.map(\.0).suffix(2) == ["drum_map", "tracks"])
    }

    private static func pattern(number: Int = 1, notes: [Note]) -> Pattern {
        Pattern(
            number: number, mode: notes.isEmpty ? .empty : .seq, hasData: !notes.isEmpty,
            seqStepCount: 16, seqSwingPercent: 50, seqBits: PatternBits.decode(20),
            drumStepCount: nil, drumSwingPercent: nil, drumBits: nil, rootNote: 0, scale: 0,
            notes: notes)
    }

    private static func project(scenes: [Scene] = []) -> Project {
        let patterns = (1...2).map { pattern(number: $0, notes: []) }
        return Project(
            device: "KeyStepPro", version: "2.5.20", tempoBPM: 120, globalSwingPercent: 50,
            currentScene: 1,
            tracks: [Track(number: 1, itemID: 123, patterns: patterns, drumMode: true)],
            scenes: scenes)
    }
}
