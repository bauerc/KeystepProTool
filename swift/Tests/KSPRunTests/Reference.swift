import CryptoKit
import Foundation
import KSPKit
import KSPRun
import Testing

/// What `tools/gen_reference.py` froze of the Python CLI, one file per parity-gate case.
enum Reference {
    static let root = RepoData.fixtures.appending(path: "reference")

    static func files(_ gate: String) -> [String] {
        let directory = root.appending(path: gate).path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    static func decode<Record: Decodable>(_ type: Record.Type, _ path: String) throws -> Record {
        try JSONDecoder().decode(type, from: Data(contentsOf: root.appending(path: path)))
    }

    /// A record that will not decode is dropped here and caught by the count in `ReferenceTests`.
    static func records<Record: Decodable>(_ gate: String) -> [Record] {
        files(gate).compactMap { try? decode(Record.self, "\(gate)/\($0)") }
    }
}

/// A written file as the reference pins it: MIDI as `midi_events.py` lines, a project by hash.
struct Artifact: Decodable, Sendable {
    let events: [String]?
    let sha256: String?
    let sameAs: String?

    enum CodingKeys: String, CodingKey {
        case events, sha256
        case sameAs = "same_as"
    }
}

struct DumpCase: Sendable, CustomTestStringConvertible {
    let file: String

    static let all = Reference.files("port_parity").map(DumpCase.init)

    var asJSON: Bool { file.hasSuffix(".json") }
    var project: String { String(file.dropLast(asJSON ? 5 : 4)) }
    var expected: URL { Reference.root.appending(path: "port_parity/\(file)") }
    var testDescription: String { asJSON ? "\(project) --json" : "\(project) tree" }
}

struct WriterCase: Sendable, CustomTestStringConvertible {
    let project: String
    let artifact: Artifact

    static let all = Reference.files("writer_parity").compactMap { file in
        (try? Reference.decode(Artifact.self, "writer_parity/\(file)")).map {
            WriterCase(project: String(file.dropLast(5)), artifact: $0)
        }
    }

    var testDescription: String { project }
}

struct PullCase: Decodable, Sendable, CustomTestStringConvertible {
    let tape: String
    let slot: Int
    let artifacts: [String: Artifact]

    static let all: [PullCase] = Reference.records("pull_parity")

    var testDescription: String { "slot \(slot) over \(tape)" }
}

struct MidiCase: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let direction: String
    let inputs: [String]
    let flags: [String]
    let exit: Int32
    let stdout: String
    let stderr: String
    let artifacts: [String: Artifact]

    static let all: [MidiCase] = Reference.records("midi_parity")

    /// A usage refusal is argument parsing, which only the executable shows, so the refusals
    /// run in `KSPSwiftCLITests`.
    static let throughTheRunners = all.filter { $0.exit != 2 }

    var testDescription: String { label }

    var prog: String { direction == "import" ? ConvertRunner.prog : ExportRunner.prog }

    /// The runner call the CLI face makes for these flags, writing under `directory`.
    func run(into directory: URL) throws -> RunResult {
        let paths = inputs.map { URL(filePath: $0, relativeTo: RepoData.root) }
        var remaining = flags.flatMap { flag -> [String] in
            guard flag.hasPrefix("--"), let equals = flag.firstIndex(of: "=") else { return [flag] }
            return [String(flag[..<equals]), String(flag[flag.index(after: equals)...])]
        }[...]
        func value() throws -> String {
            guard let value = remaining.popFirst() else {
                throw KSPError.value("\(label): a flag is missing its value")
            }
            return value
        }
        func number() throws -> Int {
            let text = try value()
            guard let number = Int(text) else { throw KSPError.value("\(label): '\(text)'") }
            return number
        }
        func unknown(_ flag: String) -> KSPError {
            KSPError.value("\(label): no runner option for \(flag)")
        }

        if direction == "import" {
            var options = ConvertRunner.Options(
                paths: paths, output: directory.appending(path: "out.KeyStepPro"),
                configPath: noPersonalConfig)
            while let flag = remaining.popFirst() {
                switch flag {
                case "--no-swing-fit": options.fitSwing = false
                case "--no-time-shift": options.fitTimeShift = false
                case "--no-drums": options.noDrums = true
                case "--steps-per-beat": options.stepsPerBeat = try number()
                case "--drum-track": options.drumTrack = try number()
                case "--drum-channel": options.drumChannel = try number() - 1
                case "--midi-track": options.midiTrack = try number()
                case "--midi-tracks": options.midiTracksSpec = try value()
                case "--route": options.routeSpec = try value()
                case "--flat-velocity": options.flatVelocitySpec = try value()
                default: throw unknown(flag)
                }
            }
            return ConvertRunner.run(options)
        }

        var options = ExportRunner.Options(
            path: paths[0],
            output: direction == "split" ? directory : directory.appending(path: "out.mid"),
            configPath: noPersonalConfig)
        while let flag = remaining.popFirst() {
            switch flag {
            case "--split": options.split = true
            case "--no-swing": options.applySwing = false
            case "--no-time-shift": options.applyTimeShift = false
            case "--no-markers": options.markers = false
            case "--include-stale": options.includeStale = true
            case "--include-disabled": options.includeDisabled = true
            case "--passes": options.passes = try number()
            case "--repeat": options.repeatCount = try number()
            case "--drum-channel": options.drumChannel = try number() - 1
            case "--drum-map": options.drumMapSpec = try value()
            case "--tracks":
                options.tracks = try parseSelection(
                    value(), option: "--tracks", limit: Constants.trackItemIDs.count)
            case "--patterns":
                options.patterns = try parseSelection(
                    value(), option: "--patterns", limit: Constants.patternsPerTrack)
            case "--flat-velocity": options.flatVelocity = try parseFlatVelocity(value())
            default: throw unknown(flag)
            }
        }
        return ExportRunner.run(options)
    }
}

/// What the CLI prints for `result`: `emit` goes through `print`, which adds the newline.
func printed(_ result: RunResult) -> String {
    result.stdout.isEmpty ? "" : result.stdout + "\n"
}

/// The gate's scrub: the output directory and the program name are all that may differ.
func scrubbed(_ text: String, directory: URL, prog: String) -> String {
    text.replacingOccurrences(of: directory.path + "/", with: "<out>/")
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.hasPrefix("\(prog): ") ? "<prog>: " + $0.dropFirst(prog.count + 2) : $0 }
        .joined(separator: "\n")
}

/// The first line two texts part at, or `nil` where they agree.
func firstDifferingLine(_ produced: String, _ expected: String) -> String? {
    guard produced != expected else { return nil }
    let producedLines = produced.split(separator: "\n", omittingEmptySubsequences: false)
    let expectedLines = expected.split(separator: "\n", omittingEmptySubsequences: false)
    let common = min(producedLines.count, expectedLines.count)
    let index = (0..<common).first { producedLines[$0] != expectedLines[$0] } ?? common
    func line(_ lines: [Substring]) -> String {
        index < lines.count ? "\"\(lines[index])\"" : "the end of the text"
    }
    return
        "line \(index + 1)\n  produced: \(line(producedLines))\n  expected: \(line(expectedLines))"
}

/// A fresh directory for one case's output, removed afterwards.
func inScratch(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "ksp-reference-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

/// Records an issue naming `label` unless `url` matches `artifact`.
func expectArtifact(_ url: URL, _ artifact: Artifact, case label: String) throws {
    let name = url.lastPathComponent
    let data = try Data(contentsOf: url)
    if let events = artifact.events {
        let produced = try midiEvents(data).joined(separator: "\n")
        if let line = firstDifferingLine(produced, events.joined(separator: "\n")) {
            Issue.record("\(label): \(name)'s MIDI events differ at \(line)")
        }
    } else if let sameAs = artifact.sameAs {
        if data != (try Data(contentsOf: RepoData.root.appending(path: sameAs))) {
            Issue.record("\(label): \(name) is not byte-identical to \(sameAs)")
        }
    } else if let digest = artifact.sha256 {
        let produced = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard produced != digest else { return }
        // The hash says only that they differ; the dump is what says where.
        let dumped = printed(
            DumpRunner.run(
                DumpRunner.Options(path: url, asJSON: true, configPath: noPersonalConfig))
        )
        let expected = try String(
            contentsOf: Reference.root.appending(path: "projects/\(digest).json"), encoding: .utf8)
        let line = firstDifferingLine(dumped, expected) ?? "nothing the dump shows"
        Issue.record("\(label): \(name) is not the Python's bytes; dump --json differs at \(line)")
    } else {
        Issue.record("\(label): \(name)'s reference record is empty")
    }
}
