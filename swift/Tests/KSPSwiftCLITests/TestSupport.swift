import Foundation

/// Repository data the tests read, resolved from this file's own path.
///
/// A twin of the one in `Tests/KSPKitTests/TestSupport.swift`: SwiftPM cannot share a source file
/// between two test targets, and neither of them should reach into the other's directory.
enum RepoData {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent()  // KSPSwiftCLITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // swift
        .deletingLastPathComponent()

    static let projectFiles = root.appending(path: "project_files")
}
