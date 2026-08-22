import Foundation
import Testing

@testable import KSPKit

/// Track 1's fourth polyphony slot is zero-filled, so a naive read yields 64 phantom notes.
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
        // Force-unwrapped deliberately: an unreadable fixture is a broken checkout.
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
        // Tempo is the one global the hardware readout confirms, so the check is independent.
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
        let raw = try Samples.raw(baseline.projectFile)
        #expect(raw.count == baseline.totalKeys)
    }

    static func load(_ baseline: Baseline) throws -> Project {
        try Samples.project(baseline.projectFile)
    }
}
