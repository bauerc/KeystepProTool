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
        public var split: Bool
        public var tracks: Set<Int>
        public var patterns: Set<Int>
        public var passes: Int?
        public var ticksPerBeat: Int
        public var drumMapSpec: String?
        /// 0-based, as `KSPMIDI` counts channels -- the CLI's `--drum-channel` is 1-based and
        /// subtracts one before it gets here.
        public var drumChannel: Int
        public var defaultGate: Double
        public var includeStale: Bool
        public var includeDisabled: Bool
        public var applySwing: Bool
        public var applyTimeShift: Bool
        public var dryRun: Bool
        public var force: Bool
        public var quiet: Bool
        public var verbose: Bool
        public var configPath: URL

        // Spelled out for the same reason as ``ConvertRunner/Options``: a public struct's
        // memberwise initialiser is internal, and every caller is in another module.
        public init(
            path: URL, output: URL? = nil, split: Bool = false, tracks: Set<Int> = [],
            patterns: Set<Int> = [], passes: Int? = nil,
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
            self.tracks = tracks
            self.patterns = patterns
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

    /// What the user sees this command called, for the message prefix on a failure.
    public static let prog = "ksp-swift-cli export"

    static func fail(_ message: String, code: Int32) -> RunResult {
        .failure(prog, message, code: code)
    }

    public static func run(_ options: Options) -> RunResult {
        let drumMap: DrumMap?
        do {
            drumMap = try resolveDrumMap(options.drumMapSpec, configPath: options.configPath)
        } catch {
            return fail("drum map: \(error)", code: 2)
        }
        guard let drumMap else {
            // `dump` can print "lane 0" and leave it unresolved; a MIDI file has no way to say
            // that, so there is nothing sensible to write.
            return fail(
                "--drum-map none cannot be exported: a MIDI file has to name a note for every "
                    + "drum lane", code: 2)
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
            return fail("\(error)", code: 2)
        }

        let project: Project
        do {
            project = try Reader.load(contentsOf: options.path)
        } catch let error as KSPError {
            return fail("\(options.path.relativePath): \(error)", code: 1)
        } catch {
            return fail("\(error.localizedDescription)", code: 1)
        }

        let planned: [(result: ExportResult, destination: URL)]
        do {
            planned = try plan(project, exportOptions, options: options)
        } catch {
            return fail("\(error)", code: 1)
        }
        if planned.isEmpty {
            // Writing a MIDI file with no notes in it would look like success.
            return fail(
                "\(options.path.relativePath): nothing to export (no selected pattern holds notes)",
                code: 1)
        }

        let existing =
            planned
            .map(\.destination)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.relativePath)
        if !existing.isEmpty && !options.force {
            return fail(
                "\(existing.joined(separator: ", ")) already exists (use --force to overwrite)",
                code: 1)
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
                return fail("\(error.localizedDescription)", code: 1)
            }
        }

        var merged = Report()
        for entry in planned {
            merged = merged.merge(entry.result.diagnostics)
        }
        var result = RunResult(
            stderr: reported(merged, verbose: options.verbose, prog: prog), diagnostics: merged,
            destinations: planned.map(\.destination))
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
        let narrowed = project.select(tracks: options.tracks, patterns: options.patterns)
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
