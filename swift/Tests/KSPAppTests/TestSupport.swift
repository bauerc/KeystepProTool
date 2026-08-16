import Foundation

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
