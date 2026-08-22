import Foundation
import Testing

@testable import KSPKit

/// The fixtures were transcribed from the device's display. **Never regenerate them from code.**
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
        // The half that catches over-reading: invented notes land in patterns nothing mentions.
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
        // Each entry asserts the file really does disagree, so a correction cannot pass silently.
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
        // The +1 the device displays for the second kick; the description first transcribed -1.
        let project = try Samples.project("project_5.KeyStepPro")
        let secondKick = project.track(1).pattern(1).notes[1]
        #expect(secondKick.step == 5)
        #expect(
            secondKick.timeShift == 1,
            "the file's value changed; re-check against project_5_description.txt")
    }

    private struct Pair: Hashable {
        let track: Int
        let pattern: Int
    }

    /// The note fields a fixture pins down; everything else on ``Note`` is implementation detail.
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

    /// The schema does not fix the type, so committing to `String` would break on a numeric one.
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
        let project = try Samples.project(fixture.projectFile)
        return (fixture, project)
    }
}
