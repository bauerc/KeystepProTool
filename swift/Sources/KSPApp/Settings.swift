import Foundation
import KSPMIDI
import KSPRun

struct Settings: Sendable, Equatable {
    /// A deliberate twin of `MIDIExport.maxRepeat`; a test pins the two together.
    static let repeatRange = 1...10

    /// Auto, or a fixed count of the device's four 16/32/48/64 sequences.
    enum StepSkip: String, CaseIterable, Identifiable, Sendable {
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

    /// The spec rather than the set, so the app hands the runner what the CLI hands it.
    func selecting(_ selection: SourceTrackSelection) -> Settings {
        var copy = self
        copy.midiTracksSpec = selection.spec
        return copy
    }

    /// `output` is `nil` for a preview, which resolves no destination because it writes nothing.
    func convertOptions(source: URL, output: URL?) -> ConvertRunner.Options {
        // `force` stays false: `Naming.vacant` found a free path, so the guard is a backstop.
        // The three ignores are the runner's own defaults inverted.
        ConvertRunner.Options(
            paths: [source], output: output, fitSwing: !ignoreSwing,
            fitTimeShift: !ignoreTimeShift,
            midiTracksSpec: midiTracksSpec,
            flatVelocitySpec: ignoreVelocity ? freshVelocitySpec : nil,
            dryRun: dryRun, verbose: verbose, configPath: drumMapConfigPath)
    }

    func exportOptions(source: URL, output: URL) -> ExportRunner.Options {
        // Splitting makes `output` the folder the runner fills, which is what `Conversion.plan`
        // hands over. The three replacements are the runner's own defaults inverted.
        ExportRunner.Options(
            path: source, output: output, split: splitPerPattern, cells: cells,
            passes: stepSkip.passes, repeatCount: repeatCount,
            flatVelocity: replaceVelocity ? MIDIExport.defaultFlatVelocity : nil,
            applySwing: !replaceSwing, applyTimeShift: !replaceTimeShift, dryRun: dryRun,
            verbose: verbose, configPath: drumMapConfigPath)
    }
}
