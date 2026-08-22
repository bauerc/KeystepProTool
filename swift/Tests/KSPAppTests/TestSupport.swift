import Foundation
import KSPKit
import KSPRun
import Testing

/// A twin per target: SwiftPM cannot share a source file between two test targets.
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

func touch(_ directory: URL, _ name: String) throws {
    try Data().write(to: directory.appending(path: name))
}

/// A `UserDefaults` domain of this test's own, so a run never reads the real preferences.
private func volatileSuite() -> (name: String, defaults: UserDefaults) {
    let name = "ksp-app-test-\(UUID().uuidString)"
    return (name, UserDefaults(suiteName: name)!)
}

func volatileDefaults() -> UserDefaults { volatileSuite().defaults }

func withVolatileDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suite = volatileSuite()
    defer { suite.defaults.removePersistentDomain(forName: suite.name) }
    try body(suite.defaults)
}

func summarise(_ name: String) throws -> ProjectSummary {
    let result = SummaryRunner.run(
        SummaryRunner.Options(path: RepoData.projectFiles.appending(path: name)))
    #expect(result.message == nil)
    return try #require(result.summary)
}

typealias SlotCount = (held: Int, enabled: Int)

/// The Chain goes onto **every** pattern it names: ``TrackSummary/chain`` reads it off the first.
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
