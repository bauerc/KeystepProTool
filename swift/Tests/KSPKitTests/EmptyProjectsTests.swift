import Foundation
import Testing

@testable import KSPKit

/// The two empty baselines must decode to nothing at all. Twin of `tests/test_empty_projects.py`,
/// reading the same `tests/fixtures/empty_projects.expected.json`.
///
/// An empty project is where a reader that mistakes uninitialised storage for content fails loudly
/// instead of subtly. Track 1's fourth polyphony slot is zero-filled rather than sentinel-filled in
/// every known file, so reading note existence naively yields 64 phantom notes per parameter set
/// per pattern -- against a file a human can confirm holds nothing.
///
/// These two files also fix what "default" means: every untouched value in `project_9` is
/// corroborated here.
@Suite struct EmptyProjectsTests {
    struct Baseline: Decodable {
        let projectFile: String
        let tempoBPM: Double
        let globalSwingPercent: Int
        let version: String?
        let totalKeys: Int
        let expectedWarningSubstrings: [String]

        enum CodingKeys: String, CodingKey {
            case version
            case projectFile = "project_file"
            case tempoBPM = "tempo_bpm"
            case globalSwingPercent = "global_swing_percent"
            case totalKeys = "total_keys"
            case expectedWarningSubstrings = "expected_warning_substrings"
        }
    }

    private struct Fixture: Decodable {
        let projects: [Baseline]
    }

    static let baselines: [Baseline] = {
        let url = RepoData.fixtures.appending(path: "empty_projects.expected.json")
        // Force-unwrapped deliberately: an unreadable fixture is a broken checkout, and failing
        // here names the file rather than failing every case with a decode error.
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(Fixture.self, from: data).projects
    }()

    @Test(arguments: baselines) func itDecodesToNoNotes(baseline: Baseline) throws {
        let project = try Self.load(baseline)
        let found = project.tracks.flatMap { track in
            track.patterns.filter { !$0.isEmpty }.map {
                "track \(track.number) pattern \($0.number): \($0.notes.count)"
            }
        }
        #expect(found.isEmpty, "decoded notes from an empty project: \(found)")
    }

    @Test(arguments: baselines) func theScalarsMatch(baseline: Baseline) throws {
        // Tempo is the one global the hardware readout confirms: 120 BPM. It is a genuinely
        // independent check on the tempo decode, because it comes from the device's own display
        // rather than from another file.
        let project = try Self.load(baseline)
        #expect(project.tempoBPM == baseline.tempoBPM)
        #expect(project.globalSwingPercent == baseline.globalSwingPercent)
        #expect(project.version == baseline.version)
    }

    @Test(arguments: baselines) func theWarningsMatch(baseline: Baseline) throws {
        let warnings = try Self.load(baseline).warnings
        #expect(warnings.count == baseline.expectedWarningSubstrings.count)
        for (substring, warning) in zip(baseline.expectedWarningSubstrings, warnings) {
            #expect(warning.contains(substring))
        }
    }

    @Test(arguments: baselines) func theKeyCountMatches(baseline: Baseline) throws {
        // The key set is fixed; only the `version` key varies between files.
        let raw = try LenientJSON.load(
            contentsOf: RepoData.projectFiles.appending(path: baseline.projectFile))
        #expect(raw.count == baseline.totalKeys)
    }

    static func load(_ baseline: Baseline) throws -> Project {
        try Reader.load(
            contentsOf: RepoData.projectFiles.appending(path: baseline.projectFile))
    }
}
