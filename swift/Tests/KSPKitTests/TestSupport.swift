import Foundation
import KSPKit
import Testing

/// Repository data the tests read, resolved from this file's own path rather than copied in.
enum RepoData {
    static let root = URL(filePath: #filePath)
        .deletingLastPathComponent()  // KSPKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // swift
        .deletingLastPathComponent()

    static let analysis = root.appending(path: "analysis")
    static let projectFiles = root.appending(path: "project_files")

    /// Hand-transcribed from the hardware display. **Never regenerate them from the code.**
    static let fixtures = root.appending(path: "tests/fixtures")
}

/// Parsed once each per run; `Project` and `RawProject` are immutable, so sharing is safe.
enum Samples {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var raws: [String: RawProject] = [:]
    private nonisolated(unsafe) static var projects: [String: Project] = [:]
    private nonisolated(unsafe) static var datas: [String: Data] = [:]

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

    static func project(_ name: String) throws -> Project {
        if let cached = lock.withLock({ projects[name] }) { return cached }
        let project = try Reader.readProject(raw(name), sourceName: name)
        lock.withLock { projects[name] = project }
        return project
    }
}

/// `#expect(a == b)` on 3.5 MB of `Data` renders both sides; an offset is the whole diagnosis.
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

/// Requiring the comma to be there keeps a mangled sample from silently becoming the baseline.
func withoutTrailingComma(_ data: Data) -> Data {
    #expect(data.suffix(3) == Data(",\n}".utf8), "sample does not end with MCC's trailing comma")
    return data.dropLast(3) + Data("\n}".utf8)
}

/// Throwing rather than lenient: a mistyped fixture is a mistake, not a frame of zero bytes.
func hexBytes(_ hex: String) throws -> [UInt8] {
    var frame: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
            let byte = UInt8(hex[index..<next], radix: 16)
        else {
            throw KSPError.value("\(hex) is not a run of hex bytes")
        }
        frame.append(byte)
        index = next
    }
    return frame
}

func hexString(_ frame: [UInt8]) -> String {
    frame.map { ($0 < 0x10 ? "0" : "") + String($0, radix: 16) }.joined()
}

/// Frame 9 of the capture, the device's answer to the identity request.
func identityReply() throws -> [UInt8] {
    let capture = RepoData.root.appending(
        path: "usb_midi_investigation/sysex_until_project_1_track_1_pattern_1.jsonl")
    for line in try String(contentsOf: capture, encoding: .utf8).split(separator: "\n") {
        guard
            let frame = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            frame["frame_number"] as? Int == 9,
            let sysex = frame["sysex_hex"] as? String
        else { continue }
        return try hexBytes(sysex)
    }
    throw KSPError.value("no frame 9 in \(capture.path)")
}
