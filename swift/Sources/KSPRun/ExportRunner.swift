import Foundation
import KSPKit
import KSPMIDI
import SwiftMIDIFile

/// The `export` command's body, split out from its argument parsing so the exit codes and the text
/// are testable without spawning a process -- the same split `main(argv) -> int` gives the Python.
public enum ExportRunner {
    public struct Options: Sendable {
        public var path: URL
        public var output: URL?
        public var split = false
        public var track: Int?
        public var pattern: Int?
        public var passes: Int?
        public var ticksPerBeat = MIDIExport.defaultTicksPerBeat
        public var drumMapSpec: String?
        public var drumChannel = MIDIExport.drumChannel
        public var defaultGate = Constants.defaultGateLength
        public var includeStale = false
        public var includeDisabled = false
        public var applySwing = true
        public var applyTimeShift = true
        public var dryRun = false
        public var force = false
        public var quiet = false
        public var verbose = false
        public var configPath: URL

        // Spelled out for the same reason as ``ConvertRunner/Options``: a public struct's
        // memberwise initialiser is internal, and every caller is in another module.
        public init(
            path: URL, output: URL? = nil, split: Bool = false, track: Int? = nil,
            pattern: Int? = nil, passes: Int? = nil,
            ticksPerBeat: Int = MIDIExport.defaultTicksPerBeat, drumMapSpec: String? = nil,
            drumChannel: Int = MIDIExport.drumChannel,
            defaultGate: Double = Constants.defaultGateLength, includeStale: Bool = false,
            includeDisabled: Bool = false, applySwing: Bool = true, applyTimeShift: Bool = true,
            dryRun: Bool = false, force: Bool = false, quiet: Bool = false, verbose: Bool = false,
            configPath: URL
        ) {
            self.path = path
            self.output = output
            self.split = split
            self.track = track
            self.pattern = pattern
            self.passes = passes
            self.ticksPerBeat = ticksPerBeat
            self.drumMapSpec = drumMapSpec
            self.drumChannel = drumChannel
            self.defaultGate = defaultGate
            self.includeStale = includeStale
            self.includeDisabled = includeDisabled
            self.applySwing = applySwing
            self.applyTimeShift = applyTimeShift
            self.dryRun = dryRun
            self.force = force
            self.quiet = quiet
            self.verbose = verbose
            self.configPath = configPath
        }
    }

    public struct Result: Sendable {
        public var stdout = ""
        public var stderr = ""
        public var code: Int32 = 0
    }

    /// What the user sees this command called, for the message prefix on a failure.
    public static let prog = "ksp-swift-cli export"

    public static func run(_ options: Options) -> Result {
        let drumMap: DrumMap?
        do {
            drumMap = try resolveDrumMap(options.drumMapSpec, configPath: options.configPath)
        } catch {
            return Result(stderr: "\(prog): drum map: \(error)\n", code: 2)
        }
        guard let drumMap else {
            // `dump` can print "lane 0" and leave it unresolved; a MIDI file has no way to say
            // that, so there is nothing sensible to write.
            return Result(
                stderr: "\(prog): --drum-map none cannot be exported: a MIDI file has to name a "
                    + "note for every drum lane\n", code: 2)
        }

        let exportOptions: ExportOptions
        do {
            exportOptions = try ExportOptions(
                ticksPerBeat: options.ticksPerBeat, drumMap: drumMap,
                drumChannel: options.drumChannel, defaultGate: options.defaultGate,
                applySwing: options.applySwing, applyTimeShift: options.applyTimeShift,
                includeStale: options.includeStale, includeDisabled: options.includeDisabled,
                passes: options.passes)
        } catch {
            return Result(stderr: "\(prog): \(error)\n", code: 2)
        }

        let project: Project
        do {
            project = try Reader.load(contentsOf: options.path)
        } catch let error as KSPError {
            return Result(stderr: "\(prog): \(options.path.relativePath): \(error)\n", code: 1)
        } catch {
            return Result(stderr: "\(prog): \(error.localizedDescription)\n", code: 1)
        }

        let planned: [(result: ExportResult, destination: URL)]
        do {
            planned = try plan(project, exportOptions, options: options)
        } catch {
            return Result(stderr: "\(prog): \(error)\n", code: 1)
        }
        if planned.isEmpty {
            // Writing a MIDI file with no notes in it would look like success.
            return Result(
                stderr:
                    "\(prog): \(options.path.relativePath): nothing to export (no selected pattern "
                    + "holds notes)\n", code: 1)
        }

        let existing =
            planned
            .map(\.destination)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.relativePath)
        if !existing.isEmpty && !options.force {
            return Result(
                stderr: "\(prog): \(existing.joined(separator: ", ")) already exists (use --force "
                    + "to overwrite)\n", code: 1)
        }

        if !options.dryRun {
            do {
                for entry in planned {
                    try FileManager.default.createDirectory(
                        at: entry.destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                }
                for entry in planned {
                    try entry.result.midi.rawData().write(to: entry.destination)
                }
            } catch {
                return Result(stderr: "\(prog): \(error.localizedDescription)\n", code: 1)
            }
        }

        var merged = Report()
        for entry in planned {
            merged = merged.merge(entry.result.diagnostics)
        }
        var result = Result(stderr: reported(merged, verbose: options.verbose))
        if !options.quiet {
            result.stdout =
                planned
                .map { summary($0.result, destination: $0.destination, dryRun: options.dryRun) }
                .joined(separator: "\n")
        }
        return result
    }

    /// Pair each rendered file with where it goes. Nothing is written yet.
    static func plan(_ project: Project, _ exportOptions: ExportOptions, options: Options) throws
        -> [(result: ExportResult, destination: URL)]
    {
        let narrowed = project.select(track: options.track, pattern: options.pattern)
        if options.split {
            let directory = options.output ?? options.path.deletingLastPathComponent()
            return try MIDIExport.exportSplit(narrowed, options: exportOptions).map {
                ($0, directory.appending(path: splitName(options.path, $0)))
            }
        }
        let result = try MIDIExport.exportProject(narrowed, options: exportOptions)
        if result.isEmpty { return [] }
        let destination =
            options.output
            ?? options.path.deletingPathExtension().appendingPathExtension("mid")
        return [(result, destination)]
    }

    /// `<stem>_track{N}_pattern{P}.mid` -- one file holds exactly one of each.
    static func splitName(_ source: URL, _ result: ExportResult) -> String {
        let stem = source.deletingPathExtension().lastPathComponent
        return "\(stem)_track\(result.trackNumbers[0])_pattern\(result.patternNumbers[0]).mid"
    }

    static func summary(_ result: ExportResult, destination: URL, dryRun: Bool) -> String {
        let patterns = result.patternNumbers.map(String.init).joined(separator: ", ")
        let tracks = result.trackNames.joined(separator: ", ")
        let verb = dryRun ? "would write" : "wrote"
        return """
            \(verb) \(destination.relativePath)
              \(result.noteCount) note(s) from pattern(s) \(patterns)
              tracks: \(tracks)
            """
    }
}

/// A report as the CLI prints it: one line per kind unless `verbose`, then the "there is more"
/// note. A port of `ksp_cli.reporting.print_report`, shared by both converting commands.
func reported(_ report: Report, verbose: Bool, prog: String = ExportRunner.prog) -> String {
    var lines = report.render(verbose: verbose).map { "\(prog): warning: \($0)\n" }
    if let note = report.note(verbose: verbose) {
        // No "warning:" prefix: this is about the report, not a finding.
        lines.append("\(prog): \(note)\n")
    }
    return lines.joined()
}
