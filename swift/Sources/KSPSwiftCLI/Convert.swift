import ArgumentParser
import Foundation
import KSPKit
import KSPMIDI
import KSPRun

/// A project file is never synthesised: its key set is fixed at 153,495 numeric keys, so a template
/// is loaded and values are overwritten in it.
struct Convert: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert",
        abstract: "Convert Standard MIDI files into an Arturia KeyStep Pro project.",
        discussion: """
            Every note-bearing track of every file is converted, onto the device's four. Each is \
            anchored so its first note lands on step 1, quantised to the step grid, and cut into \
            64-step patterns if it runs longer -- chained, never truncated. Note lengths, velocity \
            and tempo are carried. Several files merge in argument order, their tracks numbered \
            on through one another. --midi-track converts a single track of a single file \
            instead, into the one pattern --track and --pattern name.
            """)

    @Argument(
        help: "one or more Standard MIDI files, merged in argument order", completion: .file())
    var paths: [String]

    @Option(
        name: [.customShort("o"), .customLong("output")],
        help: """
            destination .KeyStepPro file (default: the first input file with a .KeyStepPro suffix)
            """)
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

    @Option(name: .customLong("route"), help: ArgumentHelp(routeHelp, valueName: "SPEC"))
    var route: String?

    @Option(
        name: .customLong("segment-bars"), help: ArgumentHelp(segmentBarsHelp, valueName: "SPEC"))
    var segmentBars: String?

    @Option(name: .customLong("drum-map"), help: ArgumentHelp(drumMapHelp, valueName: "SPEC"))
    var drumMapSpec: String?

    @Option(
        name: .customLong("flat-velocity"),
        help: ArgumentHelp(
            """
            write every note and trigger at this velocity instead of the source's: 'fresh' \
            for the measured fresh-note velocity (\(MIDIExport.defaultFlatVelocity)), or 1-127
            """, valueName: "VALUE"))
    var flatVelocity: String?

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
        name: .customLong("midi-tracks"),
        help: ArgumentHelp(midiTracksHelp, valueName: "LIST"))
    var midiTracks: String?

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
                paths: paths.map { URL(filePath: $0) },
                output: output.map { URL(filePath: $0) },
                track: track, pattern: pattern, drumTrack: drumTrack, routeSpec: route,
                segmentBarsSpec: segmentBars, drumMapSpec: drumMapSpec,
                carryTempo: !noTempo, fitSwing: !noSwingFit, fitTimeShift: !noTimeShift,
                template: template.map { URL(filePath: $0) },
                midiTrack: midiTrack, midiTracksSpec: midiTracks,
                flatVelocitySpec: flatVelocity, stepsPerBeat: stepsPerBeat, dryRun: dryRun,
                force: force, quiet: quiet, verbose: verbose, configPath: drumMapConfigPath))
        try emit(result)
    }
}
