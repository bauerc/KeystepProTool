import Foundation
import KSPKit
import Testing

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
    private nonisolated(unsafe) static var datas: [String: Data] = [:]

    /// Every sample under `project_files/`. `SAMPLE_NAMES` in `tests/conftest.py`.
    static let names = [
        "Default.KeyStepPro",
        "baseline.KeyStepPro",
        "initial_project.KeyStepPro",
        "project_5.KeyStepPro",
        "project_9.KeyStepPro",
        "user_empty_project.KeyStepPro",
    ]

    /// MCC's own bytes, as checked in.
    static func bytes(_ name: String) throws -> Data {
        if let cached = lock.withLock({ datas[name] }) { return cached }
        let data = try Data(contentsOf: RepoData.projectFiles.appending(path: name))
        lock.withLock { datas[name] = data }
        return data
    }

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

/// Where two payloads first differ, in a sentence, or `nil` if they match.
///
/// `#expect(produced == expected)` on 3.5 MB of `Data` renders both sides into the failure
/// message, which is minutes of output for a one-byte drift. A round trip fails *at an offset*,
/// and that -- with the line either side of it -- is the whole diagnosis.
func firstDifference(_ produced: Data, _ expected: Data) -> String? {
    guard produced != expected else { return nil }

    var offset = 0
    while offset < min(produced.count, expected.count),
        produced[produced.startIndex + offset] == expected[expected.startIndex + offset]
    {
        offset += 1
    }

    func window(_ data: Data) -> String {
        let start = data.index(data.startIndex, offsetBy: max(0, offset - 40))
        let end = data.index(data.startIndex, offsetBy: min(data.count, offset + 40))
        return String(decoding: data[start..<end], as: UTF8.self)
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    return """
        byte \(offset) of \(expected.count) (produced \(produced.count) bytes)
          produced: ...\(window(produced))...
          expected: ...\(window(expected))...
        """
}

/// MCC's bytes minus the comma before the closing brace -- the M3 target, and M11's.
///
/// Requiring the comma to be there to begin with keeps a mangled sample from silently becoming
/// the baseline (spec section 2). `without_trailing_comma` in `tests/conftest.py`.
func withoutTrailingComma(_ data: Data) -> Data {
    #expect(data.suffix(3) == Data(",\n}".utf8), "sample does not end with MCC's trailing comma")
    return data.dropLast(3) + Data("\n}".utf8)
}
