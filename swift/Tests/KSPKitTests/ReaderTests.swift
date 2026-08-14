import Foundation
import Testing

@testable import KSPKit

/// Twin of `tests/test_reader.py`, `tests/test_step_active.py` and `tests/test_pool_holes.py`,
/// minus the parts those files delegate to constants (already in `ConstantsTests`) and to the
/// export (M12).
///
/// `GroundTruthTests` proves the reader reproduces real files. These cover the pieces in
/// isolation, so a failure points at *which* encoding broke rather than just reporting that a note
/// came out wrong.
@Suite struct ReaderTests {
    // MARK: - Slot initialisation

    // Track 1 slot 4 is zero-filled, not sentinel-filled, in every known file.

    @Test func aZeroFilledSlotIsUninitialised() {
        let zeros = [Int?](repeating: 0, count: Constants.maxSteps)
        #expect(!Reader.slotIsInitialised(noteStep: zeros, pitch: zeros, velocity: zeros))
    }

    @Test func aSentinelFilledSlotIsInitialisedButEmpty() {
        let sentinels = [Int?](repeating: Constants.sentinel, count: Constants.maxSteps)
        #expect(
            Reader.slotIsInitialised(noteStep: sentinels, pitch: sentinels, velocity: sentinels))
    }

    @Test func aRealNoteAtStepZeroIsNotMistakenForZeroFill() {
        // The narrow test matters: step 1 with pitch 0 is a legal drum note. project_5's kick is
        // exactly that -- note->step 0, lane 0 -- so only velocity separates it from
        // uninitialised storage.
        let tail = [Int?](repeating: Constants.sentinel, count: Constants.maxSteps - 1)
        #expect(
            Reader.slotIsInitialised(
                noteStep: [0] + tail, pitch: [0] + tail, velocity: [127] + tail))
    }

    // MARK: - Project level

    @Test func aFileThatIsNotAKeyStepProProjectIsRefused() {
        let thrown = #expect(throws: KSPError.self) {
            try Reader.readProject(["some": .string("other json")])
        }
        #expect(thrown == .value("not a KeyStepPro project: missing 'device'"))
    }

    @Test func tempoReassemblesFromThreeSevenBitChunks() throws {
        // 96 + 93*128 = 12000 hundredths of a BPM.
        let raw: RawProject = [
            "device": .string("KeyStepPro"), "120_70": .int(96), "120_71": .int(93),
            "120_72": .int(0),
        ]
        #expect(try Reader.readProject(raw).tempoBPM == 120.0)
    }

    @Test func swingCarriesAPlus25Offset() throws {
        let raw: RawProject = ["device": .string("KeyStepPro"), "120_74": .int(50)]
        #expect(try Reader.readProject(raw).globalSwingPercent == 50)
    }

    @Test func aMissingVersionIsReportedRatherThanInvented() throws {
        // The factory Default.KeyStepPro omits it; user saves carry it.
        let project = try Reader.readProject(["device": .string("KeyStepPro")])
        #expect(project.version == nil)
        #expect(project.warnings.contains { $0.contains("no 'version' key") })
    }

    @Test func aVersionOfTheWrongTypeIsRefused() {
        let raw: RawProject = ["device": .string("KeyStepPro"), "version": .int(3)]
        let thrown = #expect(throws: KSPError.self) { try Reader.readProject(raw) }
        #expect(thrown == .value("'version' holds int, expected str"))
    }

    // MARK: - Scenes (item 121, parameter 84, measured by T5.7)

    @Test func aChainIsReadInOrderAndStopsAtTheSentinel() throws {
        var raw: RawProject = [
            "device": .string("KeyStepPro"), "121_84_1_2_1": .int(0), "121_84_1_2_2": .int(2),
        ]
        for slot in 3...16 { raw["121_84_1_2_\(slot)"] = .int(Constants.sentinel) }

        let chains = try Reader.readProject(raw).scenes[0].chains
        // Stored 0-based, reported the way the device numbers patterns.
        #expect(chains.count == 1)
        #expect(chains.first?.track == 2)
        #expect(chains.first?.patterns == [1, 3])
    }

    @Test func aChainWithAHoleIsReportedRatherThanAbsorbed() throws {
        // Not something the device produces, so it is not quietly repaired.
        var raw: RawProject = ["device": .string("KeyStepPro"), "121_84_1_2_1": .int(0)]
        for slot in 2...16 { raw["121_84_1_2_\(slot)"] = .int(Constants.sentinel) }
        raw["121_84_1_2_4"] = .int(5)

        let project = try Reader.readProject(raw)
        #expect(project.scenes[0].chains.first?.patterns == [1])
        #expect(project.warnings.contains { $0.contains("gap") })
    }

    @Test func noSampleProjectChainsAnything() throws {
        // 84 reads the sentinel in every slot of every file we have.
        for name in Self.sampleProjects {
            #expect(try Self.load(name).chainedScenes.isEmpty, "\(name)")
        }
    }

    // MARK: - Against real files

    @Test func velocity127IsANoteNotASentinel() throws {
        // Existence is decided by the note->step parameter alone. A reader that tested velocity
        // would drop project_5's first kick entirely.
        let firstKick = try Self.load("project_5.KeyStepPro").track(1).pattern(1).notes[0]
        #expect(firstKick.velocity == Constants.sentinel)
        #expect(firstKick.kind == .drum)
    }

    @Test func theNoteIndexAndTheStepIndexDiverge() throws {
        // The whole point of M1. The tenth note sits on step 13 and its skip mask comes from step
        // 13; reading it at note index 10 would give 15, the default, rather than 12.
        let tenth = try Self.load("project_5.KeyStepPro").track(3).pattern(1).notes[9]
        #expect(tenth.index == 10)
        #expect(tenth.step == 13)
        #expect(tenth.skip == [48, 64])
    }

    @Test func theDrumSkipIsNoteIndexedUnlikeTheMelodicOne() throws {
        // project_9 test 2: one kick at step 1, playing only in sequence 32.
        let note = try Self.load("project_9.KeyStepPro").track(1).pattern(3).notes[0]
        #expect(note.step == 1)
        #expect(note.skip == [32])
    }

    @Test func aPatternCanHoldBothParameterSets() throws {
        // Parameter 100 reads 26 in every pattern of every sample and cannot say which plays;
        // parameter 86 bit 6 can. Every note is still reported, because a reader that silently
        // dropped 64 real user notes would hide exactly this surprise.
        let project = try Self.load("initial_project.KeyStepPro")
        let pattern = project.track(1).pattern(1)
        #expect(project.track(1).drumMode)
        #expect(pattern.mode == .drum)
        #expect(pattern.notes(of: .seq).count == 64)
        #expect(pattern.notes(of: .drum).count == 12)
        #expect(pattern.warnings.contains { $0.contains("is stale. Both are reported") })
    }

    @Test func theDrumModeBitTracksWhichProjectsHoldDrums() throws {
        // MCC's dictionary names parameter 86 bit 6 ("Arp/Drum mode state") and the data agrees:
        // set on Track 1 in every sample holding drum notes, clear in both empty baselines, and
        // never set on tracks 2-4, which have no drum parameter set at all.
        for (name, expected) in [
            ("project_5", true), ("project_9", true), ("initial_project", true),
            ("Default", false), ("user_empty_project", false),
        ] {
            let project = try Self.load("\(name).KeyStepPro")
            #expect(project.track(1).drumMode == expected, "\(name)")
            #expect(project.tracks.dropFirst().allSatisfy { !$0.drumMode }, "\(name)")
        }
    }

    // MARK: - The drum pool has holes and the melodic list does not

    @Test(arguments: [(5, 42), (9, 49)])
    func aPatternWithHolesReadsItsWholePool(pattern: Int, expected: Int) throws {
        // Pattern 5 read 27 of 42 before the fix, and pattern 9 read 21 of 49.
        let notes = try Self.load("initial_project.KeyStepPro").track(1).pattern(pattern)
            .notes(of: .drum)
        #expect(notes.count == expected)
    }

    @Test func pattern5RecoversTheLane12AndLane17Runs() throws {
        // Both runs sit past the pool's first hole, at ordinals 30-34 and 36-41.
        let notes = try Self.load("initial_project.KeyStepPro").track(1).pattern(5).notes(of: .drum)
        for lane in [12, 17] {
            let inLane = notes.filter { $0.pitch == lane }
            #expect(inLane.map(\.step).sorted() == [5, 13, 21, 29, 37, 45, 53, 57, 61])
            // Every one is flagged, which is what makes them live rather than stale.
            #expect(inLane.allSatisfy { $0.active })
            #expect(inLane.map(\.index).max() ?? 0 > 28, "these are the entries past the hole")
        }
    }

    @Test func theFalseAlarmsTheTruncatedScanProducedAreGone() throws {
        // The disabled-note warning must survive -- it is a real finding about the file, not an
        // artefact of the scan.
        let warnings = try Self.load("initial_project.KeyStepPro").track(1).patterns
            .flatMap(\.warnings)
        #expect(!warnings.contains { $0.contains("after the end of the note list") })
        #expect(!warnings.contains { $0.contains("flagged active but hold no note") })
        #expect(warnings.contains { $0.contains("disabled note(s), step turned off") })
    }

    @Test func everyFlaggedDrumStepHasAPooledNote() throws {
        // Finding 5's invariant: `52` is a subset of the pool, never a superset. A superset is
        // what the truncated scan manufactured. The converse stays false by design -- many pooled
        // notes carry no flag, which is D1.
        for name in Self.sampleProjects {
            let raw = try Samples.raw(name)
            let project = try Self.load(name)
            for pattern in project.track(1).patterns {
                let pooled = Set(
                    pattern.notes(of: .drum).map { LaneStep(lane: $0.pitch, step: $0.step) })
                let flagged = try Self.flags(raw, pattern: pattern.number)
                #expect(flagged.isSubset(of: pooled), "\(name) pattern \(pattern.number)")
            }
        }
    }

    // MARK: - Step-active decoding, against real user material

    @Test func pattern1Lane0IsFullyFlagged() throws {
        // The kick on steps 1, 5, 9, 13 is what `52` reads 17, 34 for. Under the superseded
        // 8-bits-per-entry reading this decoded to 1, 5, 10, 14 and disagreed with the pool.
        let lane0 = try Self.load("initial_project.KeyStepPro").track(1).pattern(1)
            .notes(of: .drum).filter { $0.pitch == 0 }
        #expect(lane0.map(\.step).sorted() == [1, 5, 9, 13])
        #expect(lane0.allSatisfy { $0.active })
    }

    @Test func pattern1Lane17IsOnlyHalfFlagged() throws {
        // The D1 situation in material nobody authored for a test: the pool holds every other
        // step, the flags hold only half of those, and the device plays the flags.
        let lane17 = try Self.load("initial_project.KeyStepPro").track(1).pattern(1)
            .notes(of: .drum).filter { $0.pitch == 17 }
        #expect(lane17.map(\.step).sorted() == [1, 3, 5, 7, 9, 11, 13, 15])
        #expect(lane17.filter(\.active).map(\.step).sorted() == [3, 7, 13, 15])
    }

    @Test func pattern3HoldsWhollyUnflaggedLanes() throws {
        let notes = try Self.load("initial_project.KeyStepPro").track(1).pattern(3).notes(of: .drum)
        for lane in [0, 19] {
            let inLane = notes.filter { $0.pitch == lane }
            #expect(!inLane.isEmpty, "lane \(lane) should hold pooled notes")
            #expect(!inLane.contains { $0.active })
        }
        // Lane 7 in the same pattern is fully flagged, so this is not a pattern where the decode
        // simply failed.
        let lane7 = notes.filter { $0.pitch == 7 }
        #expect(!lane7.isEmpty && lane7.allSatisfy { $0.active })
    }

    @Test func melodicNotesAreFlaggedInEveryCommittedFile() throws {
        // A corpus fact, not the behaviour: what the device does when they disagree is T4.5.
        let seq = try Self.load("initial_project.KeyStepPro").track(1).pattern(1).notes(of: .seq)
        #expect(!seq.isEmpty && seq.allSatisfy { $0.active })
    }

    @Test func anEmptyProjectDecodesToNoNotes() throws {
        let project = try Self.load("user_empty_project.KeyStepPro")
        #expect(project.tracks.allSatisfy { $0.patterns.allSatisfy(\.isEmpty) })
    }

    // MARK: - The flag-without-note cross-check

    // No sample project violates the invariant, so these build the violation.

    @Test func aFlaggedStepBackedByANoteIsNotReported() {
        // `active` is 0-based and `Note.step` 1-based; an off-by-one in the bridge would invent an
        // orphan for every step.
        let diagnostics = Reader.checkStepActive(
            pattern: 1, notes: [Self.seqNote(step: 1), Self.seqNote(step: 5, index: 2)],
            active: .steps([0, 4]), kind: .seq)
        #expect(!diagnostics.contains { $0.code == .flagWithoutNote })
    }

    @Test func flagsWithoutNotesAreReportedOnceInSortedStepOrder() {
        let diagnostics = Reader.checkStepActive(
            pattern: 1, notes: [Self.seqNote(step: 1)], active: .steps([0, 8, 3]), kind: .seq)
        let reported = diagnostics.filter { $0.code == .flagWithoutNote }
        #expect(reported.count == 1)
        #expect(reported.first?.detail.contains("step(s) [4, 9]") == true)
        #expect(reported.first?.subjects == 2)
    }

    @Test func noFlagsAtAllReportsNothing() {
        let diagnostics = Reader.checkStepActive(
            pattern: 1, notes: [Self.seqNote(step: 1)], active: .steps([]), kind: .seq)
        #expect(!diagnostics.contains { $0.code == .flagWithoutNote })
    }

    // MARK: - Fixtures

    static let sampleProjects = [
        "Default.KeyStepPro", "initial_project.KeyStepPro", "project_5.KeyStepPro",
        "project_9.KeyStepPro", "user_empty_project.KeyStepPro",
    ]

    static func load(_ name: String) throws -> Project {
        try Samples.project(name)
    }

    /// A minimal audible melodic note at `step`, which is 1-based.
    static func seqNote(step: Int, index: Int = 1) -> Note {
        Note(
            kind: .seq, slot: 1, index: index, step: step, pitch: 60, velocity: 100, gateRaw: 0,
            gate: 1.0, timeShift: 0, randomness: 0, skip: [])
    }

    /// Unpack `52` straight from the file, independently of the reader.
    ///
    /// Deliberately not the reader's own decode: comparing the reader against itself would pass
    /// however the pool is scanned. Steps come out 1-based to match ``Note/step``.
    static func flags(_ raw: RawProject, pattern: Int) throws -> Set<LaneStep> {
        var flagged: Set<LaneStep> = []
        for lane in 0..<Constants.drumLaneCount {
            for step in 0..<Constants.maxSteps {
                let at = Constants.drumStepActiveIndices(lane: lane, step: step)
                let value = try Keys.getInt(
                    raw, Constants.drumTrackItemID, Constants.pDrumStepActive, pattern, at.slot,
                    at.index)
                if let value, value >> at.bit & 1 == 1 {
                    flagged.insert(LaneStep(lane: lane, step: step + 1))
                }
            }
        }
        return flagged
    }
}
