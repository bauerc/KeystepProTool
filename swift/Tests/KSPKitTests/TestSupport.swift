import Foundation
import KSPKit

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

    /// The expected-value fixtures, read by both toolchains from the one copy. They were
    /// hand-transcribed from the hardware display rather than generated, which is what makes them
    /// independent of either implementation -- see `tests/fixtures/README.md`. **Never regenerate
    /// them from the code.**
    static let fixtures = root.appending(path: "tests/fixtures")
}

/// The sample projects under `project_files/`, parsed once each per run.
///
/// A sample is 3.4 MB and the suites read a handful of them from dozens of tests, where every
/// `Reader.load` parses the file afresh. The Python suite this is a port of memoises the same way:
/// `lru_cache` on `cached_load` in `tests/test_reader.py`, session-scoped fixtures in
/// `tests/conftest.py`. `Project` and `RawProject` are immutable values, so sharing one across
/// Swift Testing's parallel tests is safe.
enum Samples {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var raws: [String: RawProject] = [:]
    private nonisolated(unsafe) static var projects: [String: Project] = [:]

    /// The parsed file, before any decoding.
    static func raw(_ name: String) throws -> RawProject {
        if let cached = lock.withLock({ raws[name] }) { return cached }
        let raw = try LenientJSON.load(contentsOf: RepoData.projectFiles.appending(path: name))
        lock.withLock { raws[name] = raw }
        return raw
    }

    /// The decoded project. `sourceName` is the file name, which is what ``Reader/load`` passes.
    static func project(_ name: String) throws -> Project {
        if let cached = lock.withLock({ projects[name] }) { return cached }
        let project = try Reader.readProject(raw(name), sourceName: name)
        lock.withLock { projects[name] = project }
        return project
    }
}
