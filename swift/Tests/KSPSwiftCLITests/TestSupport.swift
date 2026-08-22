import Foundation

/// A twin per target: SwiftPM cannot share a source file between two test targets.
enum RepoData {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent()  // KSPSwiftCLITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // swift
        .deletingLastPathComponent()

    static let projectFiles = root.appending(path: "project_files")
}
