import ArgumentParser
import Foundation
import KSPKit
import KSPMIDI
import SwiftMIDIFile

/// `ksp-swift-cli export` -- write a `.KeyStepPro` project out as MIDI. A port of
/// `src/ksp_cli/export.py`, which installs as `ksp2midi`.
///
/// All the rendering lives in `KSPMIDI`; this handles arguments, paths and what gets printed.
/// Warnings go to stderr and the summary to stdout, so a pipeline can take the summary while a
/// human still sees what the export was unsure about. The file is written either way -- an
/// undecodable gate length is a caveat, not a failure.
struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Convert an Arturia KeyStep Pro project into Standard MIDI file(s).",
        discussion: """
            By default patterns that hold notes are laid end to end in pattern order in one file, \
            and pattern N starts at the same point on every track. --split writes each (track, \
            pattern) to its own file instead.
            """)

    /// How many of the four repeats to render. `auto` decides per pattern.
    enum Passes: String, ExpressibleByArgument, CaseIterable {
        case auto
        case one = "1"
        case two = "2"
        case three = "3"
        case four = "4"

        /// The number, or `nil` for `auto` -- which is what `ExportOptions` wants for it.
        var count: Int? { Int(rawValue) }
    }

    @Argument(help: "a .KeyStepPro project file", completion: .file())
    var path: String

    @Option(
        name: [.customShort("o"), .customLong("output")],
        help: """
            destination .mid file (default: the input file with a .mid suffix); with --split, a \
            directory (default: the input file's own directory)
            """)
    var output: String?

    @Flag(
        name: .customLong("split"),
        help: """
            write one file per non-empty (track, pattern), named <stem>_track{N}_pattern{P}.mid, \
            each starting at its own tick 0
            """)
    var split = false

    @Option(help: "export only this track") var track: Int?
    @Option(help: "export only this pattern") var pattern: Int?

    @Option(
        help: """
            how many of the four 16/32/48/64 repeats to render (auto: four when a pattern holds a \
            note that does not play on all four, one otherwise)
            """)
    var passes: Passes = .auto

    @Option(name: .customLong("ticks-per-beat"), help: "MIDI resolution")
    var ticksPerBeat = MIDIExport.defaultTicksPerBeat

    @Option(name: .customLong("drum-map"), help: ArgumentHelp(drumMapHelp, valueName: "SPEC"))
    var drumMapSpec: String?

    @Option(name: .customLong("drum-channel"), help: "MIDI channel for drum lanes")
    var drumChannel = MIDIExport.drumChannel + 1

    @Option(
        name: .customLong("default-gate"),
        help: ArgumentHelp(
            """
            note length in steps for a gate value outside the measured 0-127 ladder (the default \
            is the length a freshly placed note has on the device)
            """, valueName: "STEPS"))
    var defaultGate = Constants.defaultGateLength

    @Flag(
        name: .customLong("include-stale"),
        help: """
            where a pattern holds both a melodic and a drum note set, export both instead of only \
            the one parameter 86 bit 6 says the device plays
            """)
    var includeStale = false

    @Flag(
        name: .customLong("include-disabled"),
        help: """
            export notes whose step is turned off; the device does not play them, so they are \
            omitted by default
            """)
    var includeDisabled = false

    @Flag(
        name: .customLong("no-swing"),
        help: "ignore per-pattern swing and place every step on a flat grid")
    var noSwing = false

    @Flag(
        name: .customLong("no-time-shift"),
        help: "ignore each note's time shift and place every step on a flat grid")
    var noTimeShift = false

    @Flag(name: .customLong("dry-run"), help: "report what would be written, and write nothing")
    var dryRun = false

    @Flag(name: .customLong("force"), help: "overwrite the output file if it already exists")
    var force = false

    @Flag(name: .customLong("quiet"), help: "suppress the summary on stdout")
    var quiet = false

    @Flag(
        name: [.short, .long], help: "list every diagnostic instead of one summary line per kind")
    var verbose = false

    func validate() throws {
        if let track, !(1...4 ~= track) {
            throw ValidationError("'--track' must be in 1...4")
        }
        if let pattern, !(1...Constants.patternsPerTrack ~= pattern) {
            throw ValidationError("'--pattern' must be in 1...\(Constants.patternsPerTrack)")
        }
        if !(1...16 ~= drumChannel) {
            throw ValidationError("'--drum-channel' must be in 1...16")
        }
    }

    func run() throws {
        let result = ExportRunner.run(
            ExportRunner.Options(
                path: URL(filePath: path),
                output: output.map { URL(filePath: $0) },
                split: split, track: track, pattern: pattern, passes: passes.count,
                ticksPerBeat: ticksPerBeat, drumMapSpec: drumMapSpec,
                drumChannel: drumChannel - 1, defaultGate: defaultGate,
                includeStale: includeStale, includeDisabled: includeDisabled,
                applySwing: !noSwing, applyTimeShift: !noTimeShift,
                dryRun: dryRun, force: force, quiet: quiet, verbose: verbose,
                configPath: drumMapConfigPath))
        if !result.stdout.isEmpty { print(result.stdout) }
        if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
        if result.code != 0 { throw ExitStatus(code: result.code) }
    }
}

/// The command's body, split out from its argument parsing so the exit codes and the text are
/// testable without spawning a process -- the same split `main(argv) -> int` gives the Python.
enum ExportRunner {
    struct Options {
        var path: URL
        var output: URL?
        var split = false
        var track: Int?
        var pattern: Int?
        var passes: Int?
        var ticksPerBeat = MIDIExport.defaultTicksPerBeat
        var drumMapSpec: String?
        var drumChannel = MIDIExport.drumChannel
        var defaultGate = Constants.defaultGateLength
        var includeStale = false
        var includeDisabled = false
        var applySwing = true
        var applyTimeShift = true
        var dryRun = false
        var force = false
        var quiet = false
        var verbose = false
        var configPath: URL
    }

    struct Result {
        var stdout = ""
        var stderr = ""
        var code: Int32 = 0
    }

    /// What the user sees this command called, for the message prefix on a failure.
    static let prog = "ksp-swift-cli export"

    static func run(_ options: Options) -> Result {
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
