import Foundation
import KSPKit
import KSPMIDI
import SwiftMIDIFile

/// The `convert` command's body, split out from its argument parsing so the exit codes and the text
/// are testable without spawning a process -- and so M13's app can call it, which a target inside
/// the `ksp-swift-cli` executable could not be.
public enum ConvertRunner {
    public struct Options: Sendable {
        public var path: URL
        public var output: URL?
        public var track: Int
        public var pattern: Int
        public var drumTrack: Int?
        public var drumMapSpec: String?
        public var carryTempo: Bool
        public var fitSwing: Bool
        public var fitTimeShift: Bool
        public var template: URL?
        public var midiTrack: Int?
        public var stepsPerBeat: Int
        public var dryRun: Bool
        public var force: Bool
        public var quiet: Bool
        public var verbose: Bool
        public var configPath: URL

        // Spelled out because a public struct's memberwise initialiser is internal, and both
        // callers -- the CLI command and M13's app -- are in other modules. The defaults live here
        // only: repeating them on the properties would leave a second copy that never runs.
        public init(
            path: URL, output: URL? = nil, track: Int = 1, pattern: Int = 1, drumTrack: Int? = nil,
            drumMapSpec: String? = nil, carryTempo: Bool = true, fitSwing: Bool = true,
            fitTimeShift: Bool = true, template: URL? = nil, midiTrack: Int? = nil,
            stepsPerBeat: Int = Constants.defaultStepsPerBeat, dryRun: Bool = false,
            force: Bool = false, quiet: Bool = false, verbose: Bool = false, configPath: URL
        ) {
            self.path = path
            self.output = output
            self.track = track
            self.pattern = pattern
            self.drumTrack = drumTrack
            self.drumMapSpec = drumMapSpec
            self.carryTempo = carryTempo
            self.fitSwing = fitSwing
            self.fitTimeShift = fitTimeShift
            self.template = template
            self.midiTrack = midiTrack
            self.stepsPerBeat = stepsPerBeat
            self.dryRun = dryRun
            self.force = force
            self.quiet = quiet
            self.verbose = verbose
            self.configPath = configPath
        }
    }

    /// What the user sees this command called, for the message prefix on a failure.
    public static let prog = "ksp-swift-cli convert"

    static func fail(_ message: String, code: Int32) -> RunResult {
        .failure(prog, message, code: code)
    }

    /// MCC's factory default, as shipped in this target's resource bundle.
    ///
    /// Path resolution stays out of `KSPKit`, which must not decide where files are.
    public static func defaultTemplate() -> URL? {
        Bundle.module.url(forResource: "Default", withExtension: "KeyStepPro")
    }

    public static func run(_ options: Options) -> RunResult {
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
            return fail("\(error)", code: 2)
        }

        // Cheapest checks first: the destination depends only on the arguments, and a bad clip is
        // the likelier mistake. Reading the 3.5 MB template before either would spend a file read
        // and a parse to reject the command anyway.
        let destination =
            options.output
            ?? options.path.deletingPathExtension().appendingPathExtension("KeyStepPro")
        if FileManager.default.fileExists(atPath: destination.path) && !options.force {
            return fail(
                "\(destination.relativePath) already exists (use --force to overwrite)", code: 1)
        }

        let midi: MusicalMIDI1File
        do {
            midi = try MusicalMIDI1File(data: Data(contentsOf: options.path))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return fail("\(error.localizedDescription)", code: 1)
        } catch {
            return fail(
                "\(options.path.relativePath): not a readable MIDI file: \(error)", code: 1)
        }

        guard let templatePath = options.template ?? defaultTemplate() else {
            return fail("template: the bundled factory default is missing", code: 1)
        }
        let loadedTemplate: RawProject
        do {
            loadedTemplate = try LenientJSON.load(contentsOf: templatePath)
        } catch let error as KSPError {
            return fail("template: \(templatePath.relativePath): \(error)", code: 1)
        } catch {
            return fail("template: \(error.localizedDescription)", code: 1)
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
            return fail("\(error)", code: 1)
        }

        if result.noteCount == 0 {
            // A project with nothing in it looks like success and plays silence.
            return fail("\(options.path.relativePath): no notes to convert", code: 1)
        }

        if !options.dryRun {
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try LenientJSON.write(MIDIImport.saveable(result.raw), to: destination)
            } catch {
                return fail("\(error.localizedDescription)", code: 1)
            }
        }

        var output = RunResult(
            stderr: reported(result.diagnostics, verbose: options.verbose, prog: prog),
            diagnostics: result.diagnostics, destinations: [destination])
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
