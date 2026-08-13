import Foundation
import Testing

@testable import KSPKit

/// M10's acceptance check: the Swift reader must reproduce the hardware-confirmed data.
///
/// This is the twin of `tests/test_ground_truth.py`, and it reads **the same fixture files** --
/// not a translation of them. That is why M1 put the expected values in JSON rather than in inline
/// assertions: `tests/fixtures/*.expected.json` was hand-transcribed from the descriptions in
/// `analysis/`, which record settings read off the physical KeyStep Pro's display, so what it
/// encodes is what a person saw on the device and not what either reader happens to produce.
/// Checking the port against the identical file is the moment those fixtures were written for.
///
/// **Never regenerate them from either implementation.** See `tests/fixtures/README.md` for what
/// is hardware-confirmed and what is merely transcribed from the file.
@Suite struct GroundTruthTests {
    static let fixtureNames = ["project_5.expected.json", "project_9.expected.json"]

    @Test(arguments: fixtureNames) func projectScalarsMatch(name: String) throws {
        let (fixture, project) = try Self.load(name)
        #expect(project.tempoBPM == fixture.tempoBPM)
        #expect(project.globalSwingPercent == fixture.globalSwingPercent)
    }

    @Test(arguments: fixtureNames) func everyDocumentedNoteDecodesToTheDocumentedValues(
        name: String
    ) throws {
        let (fixture, project) = try Self.load(name)
        for expected in fixture.patterns {
            let pattern = project.track(expected.track).pattern(expected.pattern)
            let location = "track \(expected.track) pattern \(expected.pattern)"

            #expect(pattern.mode.rawValue == expected.mode, "\(location)")
            if let count = expected.seqStepCount {
                #expect(pattern.seqStepCount == count, "\(location)")
            }
            if let count = expected.drumStepCount {
                #expect(pattern.drumStepCount == count, "\(location)")
            }

            #expect(pattern.notes.count == expected.notes.count, "\(location)")
            for (actual, wanted) in zip(pattern.notes, expected.notes) {
                #expect(Self.comparable(actual) == wanted, "\(location) note \(wanted.index)")
            }
        }
    }

    @Test(arguments: fixtureNames) func nothingIsDecodedOutsideTheDocumentedPatterns(
        name: String
    ) throws {
        // The half of the comparison that catches over-reading. A reader that mistakes
        // uninitialised storage for content -- Track 1 slot 4 is zero-filled in every known file
        // -- still passes the note-by-note check above, because it invents notes in patterns the
        // fixture never mentions.
        let (fixture, project) = try Self.load(name)
        let documented = Set(fixture.patterns.map { Pair(track: $0.track, pattern: $0.pattern) })
        for track in project.tracks {
            for pattern in track.patterns
            where !documented.contains(Pair(track: track.number, pattern: pattern.number)) {
                #expect(
                    pattern.notes.isEmpty,
                    """
                    track \(track.number) pattern \(pattern.number) decoded \
                    \(pattern.notes.count) note(s), but the ground truth says it is empty
                    """)
            }
        }
    }

    @Test(arguments: fixtureNames) func knownDiscrepanciesStayVisibleUntilRecheckedOnHardware(
        name: String
    ) throws {
        // Each entry asserts the file really does disagree with the description. If someone
        // re-confirms the value on the hardware and corrects one of the two, this fails and forces
        // the fixture to be updated rather than letting the conflict evaporate unnoticed.
        let (fixture, _) = try Self.load(name)
        for entry in fixture.unresolved {
            #expect(
                entry.documented != entry.inFile,
                """
                \(entry.location): \(entry.field) is recorded as unresolved but the documented and \
                in-file values now agree; delete the entry
                """)
            #expect(
                !entry.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(entry.location): unresolved entry needs an explanation")
        }
    }

    @Test func project5sSecondKickIsShiftedForward() throws {
        // The +1 the device displays for the second kick (T6.1), pinned by hand. The description
        // first transcribed -1 here; asserting the decoded value keeps the corrected reading
        // anchored to the file rather than to prose.
        let project = try Reader.load(
            contentsOf: RepoData.projectFiles.appending(path: "project_5.KeyStepPro"))
        let secondKick = project.track(1).pattern(1).notes[1]
        #expect(secondKick.step == 5)
        #expect(
            secondKick.timeShift == 1,
            "the file's value changed; re-check against project_5_description.txt")
    }

    // MARK: - Reading the fixtures

    private struct Pair: Hashable {
        let track: Int
        let pattern: Int
    }

    /// The note fields a fixture pins down. Everything else on ``Note`` -- the raw gate value, the
    /// step-active flag -- is implementation detail the ground truth documents say nothing about.
    struct ComparableNote: Decodable, Equatable {
        let kind: String
        let slot: Int
        let index: Int
        let step: Int
        let pitch: Int
        let velocity: Int
        let gate: Double?
        let timeShift: Int
        let randomness: Int
        let skip: [Int]

        enum CodingKeys: String, CodingKey {
            case kind, slot, index, step, pitch, velocity, gate, randomness, skip
            case timeShift = "time_shift"
        }
    }

    struct ExpectedPattern: Decodable {
        let track: Int
        let pattern: Int
        let mode: String
        let seqStepCount: Int?
        let drumStepCount: Int?
        let notes: [ComparableNote]

        enum CodingKeys: String, CodingKey {
            case track, pattern, mode, notes
            case seqStepCount = "seq_step_count"
            case drumStepCount = "drum_step_count"
        }
    }

    /// A fixture value whose type the schema does not fix. Both lists are empty today, so
    /// committing to `String` here would break the first time someone records a numeric
    /// disagreement.
    enum Scalar: Decodable, Equatable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case null

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Int.self) {
                self = .int(value)
            } else if let value = try? container.decode(Double.self) {
                self = .double(value)
            } else {
                self = .string(try container.decode(String.self))
            }
        }
    }

    struct Unresolved: Decodable {
        let field: String
        let documented: Scalar
        let inFile: Scalar
        let detail: String
        let location: String

        enum CodingKeys: String, CodingKey {
            case field, documented, detail
            case inFile = "in_file"
            case location = "where"
        }
    }

    struct Fixture: Decodable {
        let projectFile: String
        let tempoBPM: Double
        let globalSwingPercent: Int
        let patterns: [ExpectedPattern]
        let unresolved: [Unresolved]

        enum CodingKeys: String, CodingKey {
            case patterns, unresolved
            case projectFile = "project_file"
            case tempoBPM = "tempo_bpm"
            case globalSwingPercent = "global_swing_percent"
        }
    }

    static func comparable(_ note: Note) -> ComparableNote {
        ComparableNote(
            kind: note.kind.rawValue, slot: note.slot, index: note.index, step: note.step,
            pitch: note.pitch, velocity: note.velocity, gate: note.gate,
            timeShift: note.timeShift, randomness: note.randomness, skip: note.skip)
    }

    static func load(_ name: String) throws -> (Fixture, Project) {
        let fixture = try JSONDecoder().decode(
            Fixture.self, from: Data(contentsOf: RepoData.fixtures.appending(path: name)))
        let project = try Reader.load(
            contentsOf: RepoData.projectFiles.appending(path: fixture.projectFile))
        return (fixture, project)
    }
}
