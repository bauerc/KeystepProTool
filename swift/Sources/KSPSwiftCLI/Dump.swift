import ArgumentParser
import Foundation
import KSPKit
import KSPRun

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
        try emit(result)
    }
}
