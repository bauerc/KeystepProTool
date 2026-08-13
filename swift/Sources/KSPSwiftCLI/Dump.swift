import ArgumentParser
import Foundation
import KSPKit

/// `ksp-swift-cli dump` -- print the contents of a `.KeyStepPro` project. A port of
/// `src/ksp_cli/dump.py`.
///
/// Inspect a project file without opening MIDI Control Center.
struct Dump: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump",
        abstract: "Print the contents of an Arturia KeyStep Pro project file.")

    @Argument(help: "a .KeyStepPro project file", completion: .file())
    var path: String

    @Flag(
        name: .customLong("all"),
        help: "include patterns that hold no notes (all 16 are always present)")
    var showAll = false

    @Option(help: "show only this track") var track: Int?
    @Option(help: "show only this pattern") var pattern: Int?

    @Flag(name: .customLong("json"), help: "emit the decoded model as JSON instead of a tree")
    var asJSON = false

    @Option(name: .customLong("drum-map"), help: ArgumentHelp(drumMapHelp, valueName: "SPEC"))
    var drumMapSpec: String?

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
    }

    func run() throws {
        let result = DumpRunner.run(
            DumpRunner.Options(
                path: URL(filePath: path), showAll: showAll, track: track, pattern: pattern,
                asJSON: asJSON, drumMapSpec: drumMapSpec, verbose: verbose,
                configPath: drumMapConfigPath))
        if !result.stdout.isEmpty { print(result.stdout) }
        if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
        if result.code != 0 { throw ExitStatus(code: result.code) }
    }
}

/// The command's body, split out from its argument parsing so the exit codes and the text are
/// testable without spawning a process -- the same split `main(argv) -> int` gives the Python.
enum DumpRunner {
    struct Options {
        var path: URL
        var showAll = false
        var track: Int?
        var pattern: Int?
        var asJSON = false
        var drumMapSpec: String?
        var verbose = false
        var configPath: URL
    }

    struct Result {
        var stdout = ""
        var stderr = ""
        var code: Int32 = 0
    }

    /// What the user sees this command called, for the message prefix on a failure.
    static let prog = "ksp-swift-cli dump"

    static func run(_ options: Options) -> Result {
        let drumMap: DrumMap?
        do {
            drumMap = try resolveDrumMap(options.drumMapSpec, configPath: options.configPath)
        } catch {
            // A bad flag or a malformed config is a usage failure, not a bad file.
            return Result(stderr: "\(prog): drum map: \(error)\n", code: 2)
        }

        let project: Project
        do {
            project = try Reader.load(contentsOf: options.path)
        } catch let error as KSPError {
            return Result(stderr: "\(prog): \(options.path.path): \(error)\n", code: 1)
        } catch {
            // Its message already names the file.
            return Result(stderr: "\(prog): \(error.localizedDescription)\n", code: 1)
        }

        let selected = project.select(track: options.track, pattern: options.pattern)
        let text =
            options.asJSON
            ? selected.toJSON(drumMap: drumMap).serialised()
            : formatProject(
                selected, showAll: options.showAll, drumMap: drumMap, verbose: options.verbose)
        return Result(stdout: text)
    }
}
