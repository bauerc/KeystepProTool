import Foundation

/// Repository data the tests read, resolved from this file's own path rather than copied in.
public enum RepoData {
    public static let root = URL(filePath: #filePath)
        .deletingLastPathComponent()  // KSPTestSupport
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // swift
        .deletingLastPathComponent()

    public static let analysis = root.appending(path: "analysis")
    public static let projectFiles = root.appending(path: "project_files")

    /// Hand-transcribed from the hardware display. **Never regenerate them from the code.**
    public static let fixtures = root.appending(path: "fixtures")
}
