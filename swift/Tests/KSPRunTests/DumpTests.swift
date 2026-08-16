import Foundation
import KSPKit
import Testing

@testable import KSPRun

/// Twin of `tests/test_dump_cli.py`: argument handling and output shape.
///
/// Every case goes through ``DumpRunner/run(_:)``, which is what the `dump` subcommand's `run()`
/// calls -- the same split the Python has between the command function and `format_project`, so
/// the exit codes and the text are testable without spawning a process.
@Suite struct DumpTests {
    /// Keeps the suite independent of whoever's machine it runs on: the config file the CLI would
    /// otherwise read is a real path under `~/.config`.
    static let noPersonalConfig = URL(filePath: "/nonexistent/keysteppro/drum_map.json")

    static func run(
        _ name: String, showAll: Bool = false, track: Int? = nil, pattern: Int? = nil,
        asJSON: Bool = false, drumMap: String? = nil, verbose: Bool = false,
        configPath: URL = noPersonalConfig
    ) -> RunResult {
        DumpRunner.run(
            DumpRunner.Options(
                path: RepoData.projectFiles.appending(path: name), showAll: showAll,
                tracks: track.map { [$0] } ?? [], patterns: pattern.map { [$0] } ?? [],
                asJSON: asJSON, drumMapSpec: drumMap, verbose: verbose,
                configPath: configPath))
    }

    // MARK: - The tree

    @Test func itDumpsAProjectAsATree() {
        let result = Self.run("project_5.KeyStepPro")
        #expect(result.code == 0)
        #expect(result.stdout.contains("Track 1 (item 123)"))
        #expect(result.stdout.contains("Track 3 (item 125)"))
        // The documented drum hits and the melodic line that validates the two index spaces both
        // have to appear.
        #expect(result.stdout.contains("lane 0"))
        #expect(result.stdout.contains("C#2 (49)"))
        #expect(result.stdout.contains("tempo 120 BPM"))
    }

    @Test func emptyPatternsAreHiddenUnlessAskedFor() {
        // All 16 patterns always exist on disk; only some hold anything. Printing 64 empty
        // patterns by default would bury the two that matter.
        #expect(Self.run("project_5.KeyStepPro").stdout.occurrences(of: "Pattern ") == 2)
        #expect(
            Self.run("project_5.KeyStepPro", showAll: true).stdout.occurrences(of: "Pattern ") == 64
        )
    }

    @Test func itSelectsASingleTrackAndPattern() {
        let result = Self.run("project_9.KeyStepPro", track: 1, pattern: 3)
        #expect(result.code == 0)
        #expect(result.stdout.contains("Track 1"))
        #expect(!result.stdout.contains("Track 3"))
        #expect(result.stdout.occurrences(of: "Pattern ") == 1)
        #expect(result.stdout.contains("seq 32"))  // test 2's step skip
    }

    @Test func aShortGatePrintsItsMeasuredLength() {
        // initial_project's drum notes store gate 2, which used to print `?(2)`. The tier 2 sweep
        // resolved it: stored 2 is detent 3, 0.1875 of a step.
        let result = Self.run("initial_project.KeyStepPro", track: 1, pattern: 1)
        #expect(result.stdout.contains("gate 0.1875"))
        #expect(!result.stdout.contains("?("))
    }

    @Test func anEmptyProjectSaysSo() {
        let result = Self.run("user_empty_project.KeyStepPro")
        #expect(result.code == 0)
        #expect(result.stdout.contains("(no patterns hold notes)"))
    }

    // MARK: - JSON

    @Test func theJSONOutputRoundTrips() throws {
        let result = Self.run("project_5.KeyStepPro", asJSON: true)
        #expect(result.code == 0)
        let payload = try Self.json(result.stdout)
        #expect(payload["tempo_bpm"] as? Double == 120.0)
        #expect((payload["tracks"] as? [[String: Any]])?.count == 4)
        #expect(try Self.drumNotes(payload).map { $0["step"] as? Int } == [1, 5])
    }

    @Test func theJSONAndTheTreeAgreeOnTheSelection() throws {
        // Filtering happens once, on the model, so the two outputs cannot drift.
        let payload = try Self.json(Self.run("project_5.KeyStepPro", track: 3, asJSON: true).stdout)
        let tracks = try #require(payload["tracks"] as? [[String: Any]])
        #expect(tracks.map { $0["track"] as? Int } == [3])
        #expect(!Self.run("project_5.KeyStepPro", track: 3).stdout.contains("Track 1"))
    }

    // MARK: - The drum map

    // The map is a device global setting that no project file contains, so the CLI's job is to be
    // explicit about which one it used and to let the user say otherwise.

    @Test func lanesResolveByDefault() {
        let out = Self.run("project_5.KeyStepPro", track: 1).stdout
        #expect(out.contains("lane 0 -> C1 (36) Bass Drum 1"))
        #expect(out.contains("drum map: chromatic from 36 (assumed - not in file)"))
    }

    @Test func noneReproducesTheUnresolvedOutput() {
        // The default must not quietly rewrite what --drum-map none shows.
        let out = Self.run("project_5.KeyStepPro", drumMap: "none").stdout
        #expect(out.contains("lane 0 "))
        #expect(!out.contains("->"))
        #expect(!out.contains("drum map:"))
    }

    @Test func aCustomMapChangesTheNote() {
        let notes = (60..<84).map(String.init).joined(separator: ",")
        let out = Self.run("project_5.KeyStepPro", drumMap: "custom:\(notes)").stdout
        #expect(out.contains("lane 0 -> C3 (60) Hi Bongo"))
        #expect(out.contains("drum map: custom (assumed - not in file)"))
    }

    @Test func theJSONCarriesTheMapAndTheResolvedNotes() throws {
        let payload = try Self.json(Self.run("project_5.KeyStepPro", asJSON: true).stdout)
        let map = try #require(payload["drum_map"] as? [String: Any])
        #expect(map["name"] as? String == "chromatic-36")
        let drum = try Self.drumNotes(payload)
        #expect(drum.map { $0["drum_note"] as? Int } == [36, 36])
        #expect(drum.map { $0["drum_note_name"] as? String } == ["C1", "C1"])
    }

    @Test func theJSONOmitsTheMapWhenLanesAreNotResolved() throws {
        let payload = try Self.json(
            Self.run("project_5.KeyStepPro", asJSON: true, drumMap: "none").stdout)
        #expect(payload["drum_map"] == nil)
        #expect(try Self.drumNotes(payload)[0]["drum_note"] == nil)
    }

    @Test func melodicNotesAreUntouchedByTheMap() {
        #expect(Self.run("project_5.KeyStepPro", track: 3).stdout.contains("C#2 (49)"))
    }

    @Test func drumModeIsShownOnTheTrack() {
        #expect(
            Self.run("project_5.KeyStepPro", track: 1).stdout
                .contains("Track 1 (item 123)  [drum mode]"))
    }

    @Test func aBadMapIsAUsageError() {
        // 2, the same as ksp2midi: a bad flag is a usage error, not a bad file.
        let result = Self.run("project_5.KeyStepPro", drumMap: "chromatic:200")
        #expect(result.code == 2)
        #expect(result.stderr.contains("drum map:"))
    }

    @Test func aConfigFileIsUsedWhenNoFlagIsGiven() throws {
        let config = try tempFile(#"{"mode": "chromatic", "low": 60}"#, suffix: ".json")
        defer { try? FileManager.default.removeItem(at: config) }

        let out = Self.run("project_5.KeyStepPro", track: 1, configPath: config).stdout
        #expect(out.contains("lane 0 -> C3 (60) Hi Bongo"))
    }

    // MARK: - Failures

    @Test func aMissingFileIsAFileFailure() {
        let result = DumpRunner.run(
            DumpRunner.Options(
                path: URL(filePath: "/nonexistent/nope.KeyStepPro"),
                configPath: Self.noPersonalConfig))
        #expect(result.code == 1)
        #expect(result.stderr.hasPrefix("ksp-swift-cli dump:"))
    }

    @Test func aFileThatIsNotAProjectIsAFormatFailure() throws {
        let path = try tempFile(#"{"device": 5}"#, suffix: ".KeyStepPro")
        defer { try? FileManager.default.removeItem(at: path) }

        let result = DumpRunner.run(
            DumpRunner.Options(path: path, configPath: Self.noPersonalConfig))
        #expect(result.code == 1)
        #expect(result.stderr.contains("missing 'device'"))
    }

    // MARK: - The --drum-map grammar

    // Twin of `TestConfig` in `tests/test_drum_map.py`, which exercises it through this layer.

    @Test(arguments: [("chromatic:36", 36), ("chromatic:48", 48), ("chromatic", 36)])
    func chromaticSpecsParse(spec: String, first: Int) throws {
        #expect(try parseDrumMap(spec)?.notes.first == first)
    }

    @Test func aCustomSpecParses() throws {
        let notes = (36..<60).map(String.init).joined(separator: ",")
        #expect(try parseDrumMap("custom:\(notes)")?.notes == Array(36..<60))
    }

    @Test func noneMeansDoNotResolve() throws {
        #expect(try parseDrumMap("none") == nil)
    }

    @Test func nonsenseIsRejected() {
        let thrown = #expect(throws: KSPError.self) { try parseDrumMap("sideways:1") }
        #expect(thrown?.description.contains("unknown drum map") == true)
    }

    @Test func aBadNumberIsNamed() {
        let thrown = #expect(throws: KSPError.self) { try parseDrumMap("chromatic:kick") }
        #expect(thrown?.description.contains("not a number") == true)
    }

    @Test func theFlagBeatsTheConfigFile() throws {
        let config = try tempFile(#"{"mode": "chromatic", "low": 50}"#, suffix: ".json")
        defer { try? FileManager.default.removeItem(at: config) }

        #expect(try resolveDrumMap("chromatic:36", configPath: config)?.notes.first == 36)
        #expect(try resolveDrumMap(nil, configPath: config)?.notes.first == 50)
    }

    @Test func itFallsBackToTheDocumentedDefault() throws {
        #expect(try resolveDrumMap(nil, configPath: Self.noPersonalConfig)?.notes == Array(36..<60))
    }

    // MARK: - Helpers

    static func json(_ text: String) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    static func drumNotes(_ payload: [String: Any]) throws -> [[String: Any]] {
        let tracks = try #require(payload["tracks"] as? [[String: Any]])
        let patterns = try #require(tracks[0]["patterns"] as? [[String: Any]])
        return try #require(patterns[0]["notes"] as? [[String: Any]])
    }
}

extension String {
    fileprivate func occurrences(of needle: String) -> Int {
        ranges(of: needle).count
    }
}
