import Foundation
import KSPDevice
import KSPKit
import KSPMIDI

/// What the pull needs of a device: the walk's transport, and the identity request that is the
/// only place the firmware version comes from.
public protocol PullDevice: Transport {
    func identify() throws -> String
}

extension DeviceTransport: PullDevice {}

/// The transport, with its requests counted for the summary.
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

        // Spelled out because a public struct's memberwise initialiser is internal.
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

    public static let prog = "ksp-swift-cli pull"

    static func fail(_ message: String, code: Int32) -> RunResult {
        .failure(prog, message, code: code)
    }

    /// One second, to one decimal, as Python's `f"{seconds:.1f}"` writes it.
    static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.1f", interval)
    }

    /// Where `--also-midi`'s export goes, and how it is rendered.
    struct MidiPlan {
        var destination: URL
        var options: ExportOptions
    }

    enum MidiPlanning {
        case plan(MidiPlan)
        case refusal(RunResult)
    }

    /// `export`'s own destination and options for the project about to be written, so the flag
    /// cannot render a different file from the command it stands in for.
    static func midiPlan(_ options: Options) -> MidiPlanning {
        let export = ExportRunner.Options(path: options.output, configPath: options.configPath)
        let destination = ExportRunner.defaultDestination(export.path)
        if destination == options.output {
            return .refusal(
                fail(
                    "--also-midi cannot write \(options.output.relativePath): the project and its "
                        + "MIDI would be the same file; name the project .KeyStepPro", code: 2))
        }
        let drumMap: DrumMap?
        do {
            // The map is a usage error, so the config file is read before the walk, not after.
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

    /// `attach` stands in for the device under a replay or a test; nil takes the one on the wire.
    public static func run(
        _ options: Options, attach: (() throws -> any PullDevice)? = nil
    ) -> RunResult {
        // From the top, not from the first frame: the 3.5 MB template parse and the write of the
        // same size are most of a run that is not at the device.
        let began = Date()

        // Everything that can refuse the run happens here: a read costs ten seconds of the
        // operator's attention, and refusing it afterwards wastes them.
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
            // Outside the count: the summary reports the size of the walk.
            let version = options.noIdentity ? BulkRead.defaultVersion : try device.identify()
            let counted = Counted(device)
            raw = try BulkRead.readRaw(
                counted, templateKeys: template.keys, version: version, slot: options.slot)
            requests = counted.requests
        } catch let error as DeviceError {
            return fail("\(error)", code: 1)
        } catch {
            // A well-formed frame that answered the wrong question, or a slot with nothing saved
            // in it. BulkRead's messages already say which.
            return fail("slot \(options.slot): \(error)", code: 1)
        }
        let reading = Date().timeIntervalSince(opened)

        // What was read has to parse as a project before it is worth writing.
        let project: Project
        do {
            // The bare name, as `Reader.load` gives it: it becomes the MIDI track name.
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
                        + "export", report: report, options: options)
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

    /// A failure once the project is on disk: its warnings were earned by a read that happened,
    /// so they still reach stderr, ahead of the refusal.
    static func refused(_ message: String, report: Report, options: Options) -> RunResult {
        var result = fail(message, code: 1)
        result.stderr = reported(report, verbose: options.verbose, prog: prog) + result.stderr
        result.diagnostics = report
        return result
    }
}
