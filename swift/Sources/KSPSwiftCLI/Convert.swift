import ArgumentParser
import Foundation
import KSPKit
import KSPMIDI
import SwiftMIDIFile

/// `ksp-swift-cli convert` -- write a MIDI clip into a `.KeyStepPro` project. A port of
/// `src/ksp_cli/convert.py`, which installs as `midi2ksp`.
///
/// A project file is never synthesised. Its key set is fixed at 153,495 numeric keys, so a template
/// is loaded and values are overwritten in it -- MIDI Control Center's factory default by default,
/// or any project `--template` points at, which is how a clip goes into a pattern of a project you
/// already have.
struct Convert: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert",
        abstract: "Convert a Standard MIDI file into an Arturia KeyStep Pro project.",
        discussion: """
            Every note-bearing track of the file is converted, onto the device's four. Each is \
            anchored so its first note lands on step 1, quantised to the step grid, and cut into \
            64-step patterns if it runs longer -- chained, never truncated. Note lengths, velocity \
            and tempo are carried. --midi-track converts a single track instead, into the one \
            pattern --track and --pattern name.
            """)

    @Argument(help: "a Standard MIDI file", completion: .file())
    var path: String

    @Option(
        name: [.customShort("o"), .customLong("output")],
        help: "destination .KeyStepPro file (default: the input file with a .KeyStepPro suffix)")
    var output: String?

    @Option(help: "KeyStep Pro track to write to")
    var track = 1

    @Option(
        help: """
            first pattern to write to. Every target pattern must be empty; a track needing more \
            than one continues into the slots after it
            """)
    var pattern = 1

    @Option(
        name: .customLong("drum-track"),
        help: ArgumentHelp(
            """
            write track N of the source as drums, onto KeyStep Pro track 1 (the only one with a \
            drum set). Counting from 1 over every track of the file. Without this, a track on the \
            GM percussion channel is used, and many files have none
            """, valueName: "N"))
    var drumTrack: Int?

    @Option(name: .customLong("drum-map"), help: ArgumentHelp(drumMapHelp, valueName: "SPEC"))
    var drumMapSpec: String?

    @Flag(
        name: .customLong("no-tempo"),
        help: "keep the template's tempo instead of taking the source's")
    var noTempo = false

    @Flag(
        name: .customLong("no-swing-fit"),
        help: "leave every pattern straight instead of fitting the source's groove to swing")
    var noSwingFit = false

    @Flag(
        name: .customLong("no-time-shift"),
        help: "quantise hard, instead of giving each note's leftover to its time shift")
    var noTimeShift = false

    @Option(
        help: """
            project to write into (default: MIDI Control Center's factory default). Point this at \
            one of your own projects to keep everything else in it
            """, completion: .file())
    var template: String?

    @Option(
        name: .customLong("midi-track"),
        help: ArgumentHelp(
            "read only track N of the source file, counting from 1 (default: all of them)",
            valueName: "N"))
    var midiTrack: Int?

    @Option(
        name: .customLong("steps-per-beat"),
        help: ArgumentHelp(
            """
            step size to quantise to (the default is 1/16 steps). Written into the pattern, so the \
            device plays back on the grid the clip was snapped to
            """, valueName: "N"))
    var stepsPerBeat = Constants.defaultStepsPerBeat

    @Flag(name: .customLong("dry-run"), help: "report what would be written, and write nothing")
    var dryRun = false

    @Flag(name: .customLong("force"), help: "overwrite an existing output file")
    var force = false

    @Flag(
        name: .customLong("quiet"),
        help: "suppress the stdout summary. Warnings still go to stderr")
    var quiet = false

    @Flag(
        name: [.short, .long], help: "list every diagnostic instead of one summary line per kind")
    var verbose = false

    func validate() throws {
        if !(1...Constants.trackItemIDs.count ~= track) {
            throw ValidationError("'--track' must be in 1...\(Constants.trackItemIDs.count)")
        }
        if !(1...Constants.patternsPerTrack ~= pattern) {
            throw ValidationError("'--pattern' must be in 1...\(Constants.patternsPerTrack)")
        }
    }

    func run() throws {
        let result = ConvertRunner.run(
            ConvertRunner.Options(
                path: URL(filePath: path),
                output: output.map { URL(filePath: $0) },
                track: track, pattern: pattern, drumTrack: drumTrack, drumMapSpec: drumMapSpec,
                carryTempo: !noTempo, fitSwing: !noSwingFit, fitTimeShift: !noTimeShift,
                template: template.map { URL(filePath: $0) }, midiTrack: midiTrack,
                stepsPerBeat: stepsPerBeat, dryRun: dryRun, force: force, quiet: quiet,
                verbose: verbose, configPath: drumMapConfigPath))
        if !result.stdout.isEmpty { print(result.stdout) }
        if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
        if result.code != 0 { throw ExitStatus(code: result.code) }
    }
}

/// The command's body, split out from its argument parsing so the exit codes and the text are
/// testable without spawning a process.
enum ConvertRunner {
    struct Options {
        var path: URL
        var output: URL?
        var track = 1
        var pattern = 1
        var drumTrack: Int?
        var drumMapSpec: String?
        var carryTempo = true
        var fitSwing = true
        var fitTimeShift = true
        var template: URL?
        var midiTrack: Int?
        var stepsPerBeat = Constants.defaultStepsPerBeat
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
    static let prog = "ksp-swift-cli convert"

    /// MCC's factory default, as shipped in this target's resource bundle.
    ///
    /// Path resolution stays in the CLI: `KSPKit` must not decide where files are.
    static func defaultTemplate() -> URL? {
        Bundle.module.url(forResource: "Default", withExtension: "KeyStepPro")
    }

    static func run(_ options: Options) -> Result {
        let importOptions: ImportOptions
        do {
            importOptions = try ImportOptions(
                stepsPerBeat: options.stepsPerBeat, midiTrack: options.midiTrack,
                drumTrack: options.drumTrack,
                drumMap: try resolveImportDrumMap(
                    options.drumMapSpec, configPath: options.configPath),
                carryTempo: options.carryTempo, fitSwing: options.fitSwing,
                fitTimeShift: options.fitTimeShift)
        } catch {
            return Result(stderr: "\(prog): \(error)\n", code: 2)
        }

        // Cheapest checks first: the destination depends only on the arguments, and a bad clip is
        // the likelier mistake. Reading the 3.5 MB template before either would spend a file read
        // and a parse to reject the command anyway.
        let destination =
            options.output
            ?? options.path.deletingPathExtension().appendingPathExtension("KeyStepPro")
        if FileManager.default.fileExists(atPath: destination.path) && !options.force {
            return Result(
                stderr: "\(prog): \(destination.relativePath) already exists (use --force to "
                    + "overwrite)\n", code: 1)
        }

        let midi: MusicalMIDI1File
        do {
            midi = try MusicalMIDI1File(data: Data(contentsOf: options.path))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return Result(
                stderr: "\(prog): \(error.localizedDescription)\n", code: 1)
        } catch {
            return Result(
                stderr: "\(prog): \(options.path.relativePath): not a readable MIDI file: "
                    + "\(error)\n", code: 1)
        }

        guard let templatePath = options.template ?? defaultTemplate() else {
            return Result(
                stderr: "\(prog): template: the bundled factory default is missing\n", code: 1)
        }
        let loadedTemplate: RawProject
        do {
            loadedTemplate = try LenientJSON.load(contentsOf: templatePath)
        } catch let error as KSPError {
            return Result(
                stderr: "\(prog): template: \(templatePath.relativePath): \(error)\n", code: 1)
        } catch {
            return Result(stderr: "\(prog): template: \(error.localizedDescription)\n", code: 1)
        }

        // --midi-track narrows the source to one track, which is the whole of the single-target
        // path: that one track, into the one pattern --track and --pattern name, at the length
        // that pattern already declares.
        let result: ImportResult
        do {
            if options.midiTrack != nil {
                result = try MIDIImport.convert(
                    midi, loadedTemplate, track: options.track, pattern: options.pattern,
                    options: importOptions)
            } else {
                result = try MIDIImport.convertSong(
                    midi, loadedTemplate, options: importOptions,
                    firstPattern: options.pattern, firstTrack: options.track)
            }
        } catch {
            return Result(stderr: "\(prog): \(error)\n", code: 1)
        }

        if result.noteCount == 0 {
            // A project with nothing in it looks like success and plays silence.
            return Result(
                stderr: "\(prog): \(options.path.relativePath): no notes to convert\n", code: 1)
        }

        if !options.dryRun {
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try LenientJSON.write(MIDIImport.saveable(result.raw), to: destination)
            } catch {
                return Result(stderr: "\(prog): \(error.localizedDescription)\n", code: 1)
            }
        }

        var output = Result(
            stderr: reported(result.diagnostics, verbose: options.verbose, prog: prog))
        if !options.quiet {
            output.stdout = summary(result, destination: destination, dryRun: options.dryRun)
        }
        return output
    }

    static func summary(_ result: ImportResult, destination: URL, dryRun: Bool) -> String {
        let verb = dryRun ? "would write" : "wrote"
        var lines = ["\(verb) \(destination.relativePath)"]

        let tracks = result.plan.tracks
        if tracks.count == 1 && tracks[0].placements.count == 1 {
            // The single-target shape, said the way it has always been said.
            lines.append(
                "  \(result.noteCount) note(s) onto track \(result.track), "
                    + "pattern \(result.pattern) (\(result.stepCount) steps)")
            return lines.joined(separator: "\n")
        }

        for plan in tracks {
            let patterns = plan.patterns
            let location =
                patterns.count == 1
                ? "pattern \(patterns[0])"
                : "patterns \(patterns[0])-\(patterns[patterns.count - 1])"
            let steps = plan.placements.map { String($0.stepCount) }.joined(separator: ", ")
            let kind = plan.isDrum ? " [drum]" : ""
            lines.append(
                "  track \(plan.track)\(kind): \(plan.notes.count) note(s), \(location) "
                    + "(\(steps) steps)")
        }
        return lines.joined(separator: "\n")
    }
}

/// The same `--drum-map` choice as `export`, except that unset means *fit to the source*.
///
/// Reading a lane back can fall through to the factory default and print what it assumed. Writing
/// one cannot: a source whose drums sit anywhere but 36-59 would have every hit dropped as
/// unmapped. So an unconfigured import fits a map to the pitches it was given, and says so.
///
/// `none` is refused rather than accepted, because a drum note stores a lane and there is no lane
/// without a map.
func resolveImportDrumMap(_ spec: String?, configPath: URL) throws -> DrumMap? {
    if spec == "none" {
        throw KSPError.value(
            "a drum note stores a lane, not a pitch, so importing drums needs a map; use "
                + "chromatic:N or custom:a,b,c, or leave --drum-map off to fit one")
    }
    if let spec { return try parseDrumMap(spec) }
    guard let data = try? Data(contentsOf: configPath) else { return nil }
    return try DrumMap.from(JSONDecoder().decode(DrumMapConfig.self, from: data))
}
