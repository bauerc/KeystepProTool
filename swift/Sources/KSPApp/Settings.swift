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
        return parts.isEmpty ? nil : "Replacing: " + parts.joined(separator: " · ")
    }

    /// `ConvertRunner`'s `track`/`pattern` are routing, not selection, so the import is untouched.
    func selecting(_ selection: GridSelection) -> Settings {
        var copy = self
        copy.cells = selection.selectedCells
        return copy
    }

    func convertOptions(source: URL, output: URL) -> ConvertRunner.Options {
        // `force` stays false: `Naming.vacant` found a free path, so the guard is a backstop.
        ConvertRunner.Options(
            paths: [source], output: output, dryRun: dryRun, verbose: verbose,
            configPath: drumMapConfigPath)
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
