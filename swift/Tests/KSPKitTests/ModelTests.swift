import Testing

@testable import KSPKit

/// The decoded object model. The bitfield arithmetic underneath ``PatternBits`` is pinned in
/// `ConstantsTests`; what is left here is the model's own behaviour -- how a note labels itself,
/// how a pattern picks between its two parameter sets, and the `to_dict` key order the two ports
/// share.
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
        // Two bits allow it; the device never produced it during T5.5, so nothing knows its name.
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
        // Tracks 2-4 have no drum parameter set at all, so asking for the drum field there must
        // not invent one.
        let pattern = Self.pattern(notes: [])
        #expect(pattern.drumBits == nil)
        #expect(pattern.bits(.drum) == pattern.seqBits)
    }

    @Test func selectNarrowsToOneTrackAndPattern() {
        let project = Self.project()
        let narrowed = project.select(track: 1, pattern: 2)
        #expect(narrowed.tracks.count == 1)
        #expect(narrowed.tracks[0].patterns.map(\.number) == [2])
        // And the fields that are not being narrowed survive it.
        #expect(narrowed.tracks[0].drumMode == project.tracks[0].drumMode)
        #expect(narrowed.tempoBPM == project.tempoBPM)
    }

    @Test func selectWithoutArgumentsKeepsEverything() {
        let project = Self.project()
        #expect(project.select().tracks.count == project.tracks.count)
    }

    @Test func onlyScenesThatChainSomethingAreReported() {
        // An unused slot reads the sentinel across all 16 entries, which is every scene of every
        // sample project.
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
        // The reader warns about an out-of-range lane separately; inventing a note here would
        // hide it.
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
        // Named there because every resolved drum note below depends on it, and it is an
        // assumption about the user's device rather than anything read from the file.
        let node = Self.project().toJSON(drumMap: try DrumMap.chromatic())
        guard case .object(let members) = node else {
            Issue.record("a project should serialise to an object")
            return
        }
        #expect(members.map(\.0).suffix(2) == ["drum_map", "tracks"])
    }

    // MARK: - Fixtures

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
