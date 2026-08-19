import Foundation

/// Repository data the tests read, resolved from this file's own path.
///
/// A twin of the one every other test target carries: SwiftPM cannot share a source file between
/// two test targets, and none of them should reach into another's directory.
enum RepoData {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent()  // KSPRunTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // swift
        .deletingLastPathComponent()

    static let projectFiles = root.appending(path: "project_files")
}

/// A drum-map config path that cannot exist, so a run never picks up a personal one.
let noPersonalConfig = URL(filePath: "/nonexistent/keysteppro/drum_map.json")

/// A file of `contents` at a unique temporary path, which is what pytest's `tmp_path` gives the
/// Python twin of this suite. The caller removes it.
func tempFile(_ contents: String, suffix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "ksp-\(UUID().uuidString)\(suffix)")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}
