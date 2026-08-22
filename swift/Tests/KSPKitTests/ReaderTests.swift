import Foundation
import Testing

@testable import KSPKit

@Suite struct ReaderTests {
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
        // Step 1 with pitch 0 is a legal drum note, so only velocity separates it from zero fill.
        let tail = [Int?](repeating: Constants.sentinel, count: Constants.maxSteps - 1)
        #expect(
            Reader.slotIsInitialised(
                noteStep: [0] + tail, pitch: [0] + tail, velocity: [127] + tail))
    }

    @Test func aFileThatIsNotAKeyStepProProjectIsRefused() {
        let thrown = #expect(throws: KSPError.self) {
            try Reader.readProject(["some": .string("other json")])
        }
        #expect(thrown == .value("not a KeyStepPro project: missing 'device'"))
    }

    @Test func tempoReassemblesFromThreeSevenBitChunks() throws {
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
        var raw: RawProject = ["device": .string("KeyStepPro"), "121_84_1_2_1": .int(0)]
        for slot in 2...16 { raw["121_84_1_2_\(slot)"] = .int(Constants.sentinel) }
        raw["121_84_1_2_4"] = .int(5)

        let project = try Reader.readProject(raw)
        #expect(project.scenes[0].chains.first?.patterns == [1])
        #expect(project.warnings.contains { $0.contains("gap") })
    }

    @Test func noSampleProjectChainsAnything() throws {
        for name in Self.sampleProjects {
            #expect(try Self.load(name).chainedScenes.isEmpty, "\(name)")
        }
    }

    @Test func velocity127IsANoteNotASentinel() throws {
        // Existence is decided by note->step alone: a velocity of 127 reads as the sentinel here.
        let firstKick = try Self.load("project_5.KeyStepPro").track(1).pattern(1).notes[0]
        #expect(firstKick.velocity == Constants.sentinel)
        #expect(firstKick.kind == .drum)
    }

    @Test func theNoteIndexAndTheStepIndexDiverge() throws {
        // The skip mask comes from the step, not the note index: at index 10 it would read 15.
        let tenth = try Self.load("project_5.KeyStepPro").track(3).pattern(1).notes[9]
        #expect(tenth.index == 10)
        #expect(tenth.step == 13)
        #expect(tenth.skip == [48, 64])
    }

    @Test func theDrumSkipIsNoteIndexedUnlikeTheMelodicOne() throws {
        let note = try Self.load("project_9.KeyStepPro").track(1).pattern(3).notes[0]
        #expect(note.step == 1)
        #expect(note.skip == [32])
    }

    @Test func aPatternCanHoldBothParameterSets() throws {
        let project = try Self.load("initial_project.KeyStepPro")
        let pattern = project.track(1).pattern(1)
        #expect(project.track(1).drumMode)
        #expect(pattern.mode == .drum)
        #expect(pattern.notes(of: .seq).count == 64)
        #expect(pattern.notes(of: .drum).count == 12)
        #expect(pattern.warnings.contains { $0.contains("is stale. Both are reported") })
    }

    @Test func theDrumModeBitTracksWhichProjectsHoldDrums() throws {
        for (name, expected) in [
            ("project_5", true), ("project_9", true), ("initial_project", true),
            ("Default", false), ("user_empty_project", false),
        ] {
            let project = try Self.load("\(name).KeyStepPro")
            #expect(project.track(1).drumMode == expected, "\(name)")
            #expect(project.tracks.dropFirst().allSatisfy { !$0.drumMode }, "\(name)")
        }
    }

    @Test(arguments: [(5, 42), (9, 49)])
    func aPatternWithHolesReadsItsWholePool(pattern: Int, expected: Int) throws {
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
            #expect(inLane.allSatisfy { $0.active })
            #expect(inLane.map(\.index).max() ?? 0 > 28, "these are the entries past the hole")
        }
    }

    @Test func theFalseAlarmsTheTruncatedScanProducedAreGone() throws {
        // The disabled-note warning must survive: it is a real finding, not a scan artefact.
        let warnings = try Self.load("initial_project.KeyStepPro").track(1).patterns
            .flatMap(\.warnings)
        #expect(!warnings.contains { $0.contains("after the end of the note list") })
        #expect(!warnings.contains { $0.contains("flagged active but hold no note") })
        #expect(warnings.contains { $0.contains("disabled note(s), step turned off") })
    }

    @Test func everyFlaggedDrumStepHasAPooledNote() throws {
        // `52` is a subset of the pool, never a superset; the converse is false by design.
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

    @Test func pattern1Lane0IsFullyFlagged() throws {
        let lane0 = try Self.load("initial_project.KeyStepPro").track(1).pattern(1)
            .notes(of: .drum).filter { $0.pitch == 0 }
        #expect(lane0.map(\.step).sorted() == [1, 5, 9, 13])
        #expect(lane0.allSatisfy { $0.active })
    }

    @Test func pattern1Lane17IsOnlyHalfFlagged() throws {
        // The pool holds every other step, the flags only half of those, and the device plays flags.
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
        // Lane 7 is fully flagged, so this is not a pattern where the decode simply failed.
        let lane7 = notes.filter { $0.pitch == 7 }
        #expect(!lane7.isEmpty && lane7.allSatisfy { $0.active })
    }

    @Test func melodicNotesAreFlaggedInEveryCommittedFile() throws {
        let seq = try Self.load("initial_project.KeyStepPro").track(1).pattern(1).notes(of: .seq)
        #expect(!seq.isEmpty && seq.allSatisfy { $0.active })
    }

    @Test func anEmptyProjectDecodesToNoNotes() throws {
        let project = try Self.load("user_empty_project.KeyStepPro")
        #expect(project.tracks.allSatisfy { $0.patterns.allSatisfy(\.isEmpty) })
    }

    // No sample project violates the invariant, so these build the violation.

    @Test func aFlaggedStepBackedByANoteIsNotReported() {
        // `active` is 0-based and `Note.step` 1-based; an off-by-one would invent an orphan.
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

    /// Not the reader's own decode: comparing the reader against itself would pass regardless.
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
