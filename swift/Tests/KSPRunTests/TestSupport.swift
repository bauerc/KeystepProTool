import Foundation

/// A twin per target: SwiftPM cannot share a source file between two test targets.
enum RepoData {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent()  // KSPRunTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // swift
        .deletingLastPathComponent()

    static let projectFiles = root.appending(path: "project_files")
    static let fixtures = root.appending(path: "tests/fixtures")
}

/// A drum-map config path that cannot exist, so a run never picks up a personal one.
let noPersonalConfig = URL(filePath: "/nonexistent/keysteppro/drum_map.json")

/// A file of `contents` at a unique temporary path. The caller removes it.
func tempFile(_ contents: String, suffix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "ksp-\(UUID().uuidString)\(suffix)")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}
