import Foundation
import KSPKit
import KSPRun
import Testing

/// Repository data the tests read, resolved from this file's own path.
///
/// A twin of the one every other test target carries: SwiftPM cannot share a source file between
/// two test targets, and none of them should reach into another's directory.
enum RepoData {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent()  // KSPAppTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // swift
        .deletingLastPathComponent()

    static let projectFiles = root.appending(path: "project_files")
}

/// An empty directory at a unique temporary path. The caller removes it.
func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "ksp-app-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// An empty file at `directory/name`, to stand in the way of a conversion.
func touch(_ directory: URL, _ name: String) throws {
    try Data().write(to: directory.appending(path: name))
}

/// A `UserDefaults` domain of this test's own, so a run never reads the account's real preferences.
private func volatileSuite() -> (name: String, defaults: UserDefaults) {
    let name = "ksp-app-test-\(UUID().uuidString)"
    return (name, UserDefaults(suiteName: name)!)
}

/// For a test that only reads: nothing reaches the disk until something is written, so there is
/// nothing to clean up. A test that saves goes through ``withVolatileDefaults(_:)``.
func volatileDefaults() -> UserDefaults { volatileSuite().defaults }

/// For a test that writes: the domain is removed once the body returns.
func withVolatileDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suite = volatileSuite()
    defer { suite.defaults.removePersistentDomain(forName: suite.name) }
    try body(suite.defaults)
}

/// A project read through the shipped runner, for a test that wants real counts rather than made-up
/// ones. A twin of ``KSPRunTests``' loader, for the reason ``RepoData`` is one.
func summarise(_ name: String) throws -> ProjectSummary {
    let result = SummaryRunner.run(
        SummaryRunner.Options(path: RepoData.projectFiles.appending(path: name)))
    #expect(result.message == nil)
    return try #require(result.summary)
}

/// How many notes one slot holds and how many of those are switched on.
typealias SlotCount = (held: Int, enabled: Int)

/// A summary assembled by hand, for the cases no sample project has: a chain, and a pattern holding
/// notes with every one of them switched off.
///
/// `chains` maps a track number onto its Chain in play order. The Chain goes onto **every** pattern
/// it names, because ``TrackSummary/chain`` reads it back off the first pattern carrying one -- set
/// it on a single pattern and the track's chain comes back empty, which would let a chain test pass
/// without testing anything.
func syntheticSummary(
    tempoBPM: Double = 120, globalSwingPercent: Int = 50, currentScene: Int = 1,
    drumTracks: Set<Int> = [], chains: [Int: [Int]] = [:],
    notes: [Int: [Int: SlotCount]] = [:]
) -> ProjectSummary {
    ProjectSummary(
        sourceName: "synthetic.KeyStepPro", tempoBPM: tempoBPM,
        globalSwingPercent: globalSwingPercent, currentScene: currentScene,
        tracks: (1...4).map { track in
            let drum = drumTracks.contains(track)
            let chain = chains[track] ?? []
            return TrackSummary(
                number: track, name: drum ? "Track \(track) (drum)" : "Track \(track)",
                mode: drum ? .drum : .sequencer,
                patterns: (1...16).map { pattern in
                    let count = notes[track]?[pattern] ?? (held: 0, enabled: 0)
                    return PatternSummary(
                        number: pattern, mode: count.held == 0 ? .empty : (drum ? .drum : .seq),
                        noteCount: count.held, enabledNoteCount: count.enabled, stepCount: 16,
                        hasData: count.held > 0, chain: chain.contains(pattern) ? chain : [])
                })
        })
}
