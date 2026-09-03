import Foundation
import KSPMIDI
import KSPRun

/// The drum designation the import runs under and the channel it searches, counting from 1.
struct DrumSense: Equatable, Sendable {
    let designation: DrumDesignation
    let channel: Int
}

struct Settings: Sendable, Equatable, Codable {
    /// A deliberate twin of `MIDIExport.maxRepeat`; a test pins the two together.
    static let repeatRange = 1...10

    /// A deliberate twin of the CLI's own `--drum-channel` check; a test pins the two together.
    static let drumChannelRange = 1...16

    /// The two designations the sidebar owns. A source track is the track list's to name.
    enum Drums: String, CaseIterable, Identifiable, Codable, Sendable {
        case automatic
        case none

        var id: String { rawValue }
        var label: String { self == .automatic ? "Automatic" : "None" }
    }

    /// Auto, or a fixed count of the device's four 16/32/48/64 sequences.
    enum StepSkip: String, CaseIterable, Identifiable, Codable, Sendable {
        case auto
        case one = "1"
        case two = "2"
        case three = "3"
        case four = "4"

        var id: String { rawValue }
        var passes: Int? { Int(rawValue) }
        var label: String { self == .auto ? "Auto" : rawValue }
    }

    var dryRun = false
    var verbose = false
    /// How much of the step-skip cycle the export renders. Export-only: an import has no cycle.
    var stepSkip: StepSkip = .auto
    /// Export-only: the device stores no such count, so no repeat of it can be written back.
    var repeatCount = 1
    /// The slots the export runs over, per track, empty meaning all.
    var cells: [Int: Set<Int>] = [:]
    /// The source tracks the import reads, `nil` meaning all. Import-only, as ``cells`` is
    /// export-only.
    var midiTracksSpec: String?
    /// Where the import sends the source tracks placed by hand, `nil` leaving the planner's own
    /// fill-upwards rule alone. Import-only, as ``midiTracksSpec`` is.
    var routeSpec: String?
    /// The source track written as drums, `nil` leaving ``drums`` to decide. Import-only, and the
    /// track list's to set, as ``midiTracksSpec`` is.
    var drumTrack: Int?
    /// Whether the import searches a channel for a kit at all. Overridden by ``drumTrack``.
    var drums: Drums = .automatic
    /// Counting from 1 as the CLI counts it; the core takes it from 0.
    var drumChannel = MIDIImport.drumChannel + 1
    var splitPerPattern = false

    /// Export every event at the measured fresh-note velocity instead of the one it stores.
    var replaceVelocity = false
    /// Export-only, and in the export's sense: an import's swing means fitting the source's groove.
    var replaceSwing = false
    /// Place every step on the grid instead of applying the offset each Note stores.
    var replaceTimeShift = false

    var replacementNote: String? {
        var parts: [String] = []
        if replaceVelocity { parts.append("velocity with \(MIDIExport.defaultFlatVelocity)") }
        if replaceSwing { parts.append("swing with a flat grid") }
        if replaceTimeShift { parts.append("time shift with a flat grid") }
        return note("Replacing: ", parts)
    }

    /// Write every note and trigger at the measured fresh-note velocity instead of the source's.
    var ignoreVelocity = false
    /// Leave every pattern straight instead of fitting the source's groove. Import-only, and in the
    /// import's sense: an export's swing is the delay the pattern already stores.
    var ignoreSwing = false
    /// Quantise hard instead of giving each note's leftover to its time shift.
    var ignoreTimeShift = false

    var ignoredNote: String? {
        var parts: [String] = []
        if ignoreVelocity { parts.append("velocity, writing \(MIDIExport.defaultFlatVelocity)") }
        if ignoreSwing { parts.append("swing, leaving every pattern straight") }
        if ignoreTimeShift { parts.append("time shift, quantising hard") }
        return note("Ignoring: ", parts)
    }

    private func note(_ prefix: String, _ parts: [String]) -> String? {
        parts.isEmpty ? nil : prefix + parts.joined(separator: " · ")
    }

    /// `ConvertRunner`'s `track`/`pattern` are routing, not selection, so the import is untouched.
    func selecting(_ selection: GridSelection) -> Settings {
        var copy = self
        copy.cells = selection.selectedCells
        return copy
    }

    /// The specs rather than the sets, so the app hands the runner what the CLI hands it.
    func selecting(_ selection: SourceTrackSelection) -> Settings {
        var copy = self
        copy.midiTracksSpec = selection.spec
        copy.routeSpec = selection.routeSpec
        copy.drumTrack = selection.drumTrack
        return copy
    }

    /// What the views draw under. A named track wins, as `--drum-track` wins over `--drum-channel`.
    func drumSense(named track: Int?) -> DrumSense {
        DrumSense(
            designation: track.map(DrumDesignation.source) ?? (drums == .none ? .none : .auto),
            channel: drumChannel)
    }

    /// `output` is `nil` for a preview, which resolves no destination because it writes nothing.
    func convertOptions(source: URL, output: URL?) -> ConvertRunner.Options {
        // `force` stays false: `Naming.vacant` found a free path, so the guard is a backstop.
        // The three ignores are the runner's own defaults inverted.
        ConvertRunner.Options(
            paths: [source], output: output, drumTrack: drumTrack,
            noDrums: drums == .none && drumTrack == nil, drumChannel: drumChannel - 1,
            routeSpec: routeSpec,
            fitSwing: !ignoreSwing,
            fitTimeShift: !ignoreTimeShift, midiTracksSpec: midiTracksSpec,
            flatVelocitySpec: ignoreVelocity ? freshVelocitySpec : nil,
            dryRun: dryRun, verbose: verbose, configPath: drumMapConfigPath)
    }

    /// `output` is `nil` for a preview, which resolves no destination because it writes nothing.
    func exportOptions(source: URL, output: URL?) -> ExportRunner.Options {
        // Splitting makes `output` the folder the runner fills, which is what `Conversion.plan`
        // hands over. The three replacements are the runner's own defaults inverted.
        ExportRunner.Options(
            path: source, output: output, split: splitPerPattern, cells: cells,
            passes: stepSkip.passes, repeatCount: repeatCount,
            flatVelocity: replaceVelocity ? MIDIExport.defaultFlatVelocity : nil,
            applySwing: !replaceSwing, applyTimeShift: !replaceTimeShift, dryRun: dryRun,
            verbose: verbose, configPath: drumMapConfigPath)
    }

    /// What survives a launch. ``cells``, ``midiTracksSpec``, ``routeSpec`` and ``drumTrack``
    /// belong to a drop rather than to a preference, so they are left out and come back as-new.
    private enum CodingKeys: String, CodingKey {
        case dryRun
        case verbose
        case stepSkip
        case repeatCount
        case drums
        case drumChannel
        case splitPerPattern
        case replaceVelocity
        case replaceSwing
        case replaceTimeShift
        case ignoreVelocity
        case ignoreSwing
        case ignoreTimeShift
    }
}

/// In an extension so the memberwise initialiser survives. Every key is optional on the way in: a
/// field added later must cost the reader that one setting, not the whole remembered set.
extension Settings {
    init(from decoder: Decoder) throws {
        let blob = try decoder.container(keyedBy: CodingKeys.self)
        let fresh = Settings()
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try blob.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        self.init()
        dryRun = try read(.dryRun, fresh.dryRun)
        verbose = try read(.verbose, fresh.verbose)
        stepSkip = try read(.stepSkip, fresh.stepSkip)
        repeatCount = try read(.repeatCount, fresh.repeatCount)
        drums = try read(.drums, fresh.drums)
        drumChannel = try read(.drumChannel, fresh.drumChannel)
        splitPerPattern = try read(.splitPerPattern, fresh.splitPerPattern)
        replaceVelocity = try read(.replaceVelocity, fresh.replaceVelocity)
        replaceSwing = try read(.replaceSwing, fresh.replaceSwing)
        replaceTimeShift = try read(.replaceTimeShift, fresh.replaceTimeShift)
        ignoreVelocity = try read(.ignoreVelocity, fresh.ignoreVelocity)
        ignoreSwing = try read(.ignoreSwing, fresh.ignoreSwing)
        ignoreTimeShift = try read(.ignoreTimeShift, fresh.ignoreTimeShift)
    }
}
