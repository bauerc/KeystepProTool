import Foundation

/// Repository data the tests read, resolved from this file's own path.
///
/// `analysis/` and `project_files/` sit outside the package and feed both toolchains, so they are
/// not bundle resources: copying them would duplicate a 3.5 MB export and a transcription that
/// cannot be regenerated without the device.
enum RepoData {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent()  // KSPKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // swift
        .deletingLastPathComponent()

    static let analysis = root.appending(path: "analysis")
    static let projectFiles = root.appending(path: "project_files")
}
