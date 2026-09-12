import Foundation
import KSPDevice
import KSPKit
import KSPMIDI

public protocol PullDevice: Transport {
    func identify() throws -> String
}

extension DeviceTransport: PullDevice {}

private final class Counted: Transport {
    private let inner: any Transport
    private(set) var requests = 0

    init(_ inner: any Transport) {
        self.inner = inner
    }

    func send(_ frame: [UInt8]) throws {
        try inner.send(frame)
    }

    func exchange(_ request: [UInt8]) throws -> [UInt8] {
        requests += 1
        return try inner.exchange(request)
    }
}

public enum PullRunner {
    public struct Options: Sendable {
        public var output: URL
        public var slot: Int
        public var noIdentity: Bool
        public var timeoutMs: Int
        public var template: URL?
        public var alsoMidi: Bool
        public var force: Bool
        public var quiet: Bool
        public var verbose: Bool
        public var configPath: URL

        public init(
            output: URL, slot: Int = Sysex.defaultSlot, noIdentity: Bool = false,
            timeoutMs: Int = DeviceTransport.defaultTimeoutMs, template: URL? = nil,
            alsoMidi: Bool = false, force: Bool = false, quiet: Bool = false,
            verbose: Bool = false, configPath: URL = drumMapConfigPath
        ) {
            self.output = output
            self.slot = slot
            self.noIdentity = noIdentity
            self.timeoutMs = timeoutMs
            self.template = template
            self.alsoMidi = alsoMidi
            self.force = force
            self.quiet = quiet
            self.verbose = verbose
            self.configPath = configPath
        }
    }

    public static let prog = "kspplus pull"

    static func fail(_ message: String, code: Int32) -> RunResult {
        .failure(prog, message, code: code)
    }

    /// One decimal place, as the pull report prints every interval.
    static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.1f", interval)
    }

    struct MidiPlan {
        var destination: URL
        var options: ExportOptions
    }

    enum MidiPlanning {
        case plan(MidiPlan)
        case refusal(RunResult)
    }

    static func midiPlan(_ options: Options) -> MidiPlanning {
        let export = ExportRunner.Options(path: options.output, configPath: options.configPath)
        let destination = ExportRunner.defaultDestination(export.path)
        // Case-folded: on a case-insensitive volume `Foo.MID` and `Foo.mid` are one file.
        if options.output.pathExtension.lowercased() == "mid" {
            return .refusal(
                fail(
                    "--also-midi cannot write \(options.output.relativePath): the project and its "
                        + "MIDI would be the same file; name the project .KeyStepPro", code: 2))
        }
        let drumMap: DrumMap?
        do {
            drumMap = try resolveDrumMap(nil, configPath: options.configPath)
        } catch {
            return .refusal(fail("drum map: \(error)", code: 2))
        }
        guard let drumMap else {
            return .refusal(
                fail(
                    "--drum-map none cannot be exported: a MIDI file has to name a note for every "
                        + "drum lane", code: 2))
        }
        do {
            return .plan(
                MidiPlan(
                    destination: destination,
                    options: try ExportRunner.exportOptions(export, drumMap: drumMap)))
        } catch {
            return .refusal(fail("\(error)", code: 2))
        }
    }

    public static func run(
        _ options: Options, attach: (() throws -> any PullDevice)? = nil
    ) -> RunResult {
        let began = Date()

        var midi: MidiPlan?
        if options.alsoMidi {
            switch midiPlan(options) {
            case .refusal(let refusal): return refusal
            case .plan(let planned): midi = planned
            }
        }
        if !options.force {
            let existing = ([options.output] + (midi.map { [$0.destination] } ?? []))
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .map(\.relativePath)
            if !existing.isEmpty {
                return fail(
                    "\(existing.joined(separator: ", ")) already exists (use --force to overwrite)",
                    code: 1)
            }
        }

        guard let templatePath = options.template ?? ConvertRunner.defaultTemplate() else {
            return fail("template: the bundled factory default is missing", code: 1)
        }
        let template: RawProject
        do {
            template = try LenientJSON.load(contentsOf: templatePath)
        } catch let error as KSPError {
            return fail("template: \(templatePath.relativePath): \(error)", code: 1)
        } catch {
            return fail("template: \(error.localizedDescription)", code: 1)
        }

        let opened = Date()
        let raw: RawProject
        let requests: Int
        do {
            let device = try attach?() ?? KeyStepPro.attach(timeoutMs: options.timeoutMs)
            let version = options.noIdentity ? BulkRead.defaultVersion : try device.identify()
            let counted = Counted(device)
            raw = try BulkRead.readRaw(
                counted, templateKeys: template.keys, version: version, slot: options.slot)
            requests = counted.requests
        } catch let error as DeviceError {
            return fail("\(error)", code: 1)
        } catch {
            return fail("slot \(options.slot): \(error)", code: 1)
        }
        let reading = Date().timeIntervalSince(opened)

        let project: Project
        do {
            project = try Reader.readProject(raw, sourceName: options.output.lastPathComponent)
        } catch {
            return fail("the device's answer is not a readable project: \(error)", code: 1)
        }

        do {
            try FileManager.default.createDirectory(
                at: options.output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LenientJSON.write(LenientJSON.canonical(raw), to: options.output)
        } catch {
            return fail("\(error.localizedDescription)", code: 1)
        }

        var report = project.diagnostics
        var destinations = [options.output]
        var midiSummary: String?
        if let midi {
            let exported: ExportResult
            do {
                exported = try MIDIExport.exportProject(project, options: midi.options)
            } catch {
                return refused("\(error)", report: report, options: options)
            }
            report = report.merge(exported.diagnostics)
            if exported.isEmpty {
                return refused(
                    "\(options.output.relativePath) was written, but no pattern holds notes to "
                        + "export", report: report, options: options, reporting: true)
            }
            do {
                try exported.midi.rawData().write(to: midi.destination)
            } catch {
                return refused(
                    "\(error.localizedDescription)", report: report, options: options)
            }
            destinations.append(midi.destination)
            midiSummary = ExportRunner.summary(
                exported, destination: midi.destination, dryRun: false, repeat: 1)
        }

        var result = RunResult(
            stderr: reported(report, verbose: options.verbose, prog: prog), diagnostics: report,
            destinations: destinations)
        if !options.quiet {
            let notes = project.tracks.reduce(0) { total, track in
                total + track.patterns.reduce(0) { $0 + $1.notes.count }
            }
            let total = Date().timeIntervalSince(began)
            result.stdout = [
                "read slot \(options.slot) in \(seconds(reading)) s, \(requests) requests",
                "wrote \(options.output.relativePath)",
                "  \(notes) note(s), \(Arithmetic.general(project.tempoBPM)) BPM",
                midiSummary,
                "  \(seconds(total)) s total, \(seconds(reading)) s of it at the device",
            ].compactMap { $0 }.joined(separator: "\n")
        }
        return result
    }

    static func refused(
        _ message: String, report: Report, options: Options, reporting: Bool = false
    ) -> RunResult {
        var result = fail(message, code: 1)
        if reporting {
            result.stderr = reported(report, verbose: options.verbose, prog: prog) + result.stderr
        }
        result.diagnostics = report
        result.destinations = [options.output]
        return result
    }
}
