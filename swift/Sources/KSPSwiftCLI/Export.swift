import ArgumentParser
import Foundation
import KSPKit
import KSPMIDI
import KSPRun

/// `ksp-swift-cli export` -- write a `.KeyStepPro` project out as MIDI. A port of
/// `src/ksp_cli/export.py`, which installs as `ksp2midi`.
///
/// All the rendering lives in `KSPMIDI` and the body in ``ExportRunner``; this is the argument
/// surface and nothing else. Warnings go to stderr and the summary to stdout, so a pipeline can
/// take the summary while a human still sees what the export was unsure about. The file is written
/// either way -- an undecodable gate length is a caveat, not a failure.
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

    @Option(
        name: [.customLong("tracks"), .customLong("track")],
        help: ArgumentHelp("export only these tracks: \(selectionHelp)", valueName: "LIST"))
    var tracks: String?

    @Option(
        name: [.customLong("patterns"), .customLong("pattern")],
        help: ArgumentHelp("export only these patterns: \(selectionHelp)", valueName: "LIST"))
    var patterns: String?

    @Option(
        help: """
            how many of the four 16/32/48/64 repeats to render (auto: four when a pattern holds a \
            note that does not play on all four, one otherwise)
            """)
    var passes: Passes = .auto

    @Option(
        name: .customLong("repeat"),
        help: ArgumentHelp(
            """
            lay the whole export down this many times end to end (1-\(MIDIExport.maxRepeat)); \
            export-only, and not the step-skip cycle --passes renders
            """, valueName: "N"))
    var repeatCount = 1

    @Option(
        name: .customLong("flat-velocity"),
        help: ArgumentHelp(
            """
            render every note at this velocity instead of the one it stores: 'fresh' for the \
            measured fresh-note velocity (\(MIDIExport.defaultFlatVelocity)), or 1-127
            """, valueName: "VALUE"))
    var flatVelocity: String?

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

    @Flag(
        name: .customLong("no-markers"),
        help: "omit the marker that names the start of each pattern")
    var noMarkers = false

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
        if !(1...16 ~= drumChannel) {
            throw ValidationError("'--drum-channel' must be in 1...16")
        }
    }

    func run() throws {
        let selectedTracks: Set<Int>
        let selectedPatterns: Set<Int>
        let parsedFlatVelocity: Int?
        do {
            selectedTracks = try parseSelection(
                tracks, option: "--tracks", limit: Constants.trackItemIDs.count)
            selectedPatterns = try parseSelection(
                patterns, option: "--patterns", limit: Constants.patternsPerTrack)
            parsedFlatVelocity = try parseFlatVelocity(flatVelocity)
        } catch {
            // Through the runner's own failure shape rather than `ValidationError`, so the wording
            // matches `ksp2midi`'s byte for byte -- ArgumentParser's would not.
            return try emit(RunResult.failure(ExportRunner.prog, "\(error)", code: 2))
        }

        let result = ExportRunner.run(
            ExportRunner.Options(
                path: URL(filePath: path),
                output: output.map { URL(filePath: $0) },
                split: split, tracks: selectedTracks,
                patterns: selectedPatterns, passes: passes.count,
                repeatCount: repeatCount, flatVelocity: parsedFlatVelocity,
                ticksPerBeat: ticksPerBeat, drumMapSpec: drumMapSpec,
                drumChannel: drumChannel - 1, defaultGate: defaultGate,
                includeStale: includeStale, includeDisabled: includeDisabled,
                applySwing: !noSwing, applyTimeShift: !noTimeShift, markers: !noMarkers,
                dryRun: dryRun, force: force, quiet: quiet, verbose: verbose,
                configPath: drumMapConfigPath))
        try emit(result)
    }
}
