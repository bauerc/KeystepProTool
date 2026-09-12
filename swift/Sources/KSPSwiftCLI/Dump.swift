import ArgumentParser
import Foundation
import KSPKit
import KSPRun

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
        if let track { try checkBound("track", track, in: 1...Constants.trackItemIDs.count) }
        if let pattern { try checkBound("pattern", pattern, in: 1...Constants.patternsPerTrack) }
    }

    func run() throws {
        let result = DumpRunner.run(
            DumpRunner.Options(
                path: URL(filePath: path), showAll: showAll, tracks: track.map { [$0] } ?? [],
                patterns: pattern.map { [$0] } ?? [],
                asJSON: asJSON, drumMapSpec: drumMapSpec, verbose: verbose,
                configPath: drumMapConfigPath))
        try emit(result)
    }
}
