import Foundation
import KSPMIDI
import KSPRun

/// What the options sidebar holds, and how it reaches the runners. No SwiftUI, so it unit-tests.
///
/// An option the sidebar does not offer is left off these mappings entirely, keeping the runner's
/// own default -- which is what makes the app on defaults convert what the CLI on defaults converts.
struct Settings: Sendable, Equatable {
    /// What the stepper offers. A deliberate twin of `MIDIExport.maxRepeat`, for the reason
    /// ``StepSkip`` is one; a test pins the two together so the control cannot drift past what the
    /// export accepts.
    static let repeatRange = 1...10

    /// Auto, or a fixed count of the device's four 16/32/48/64 sequences.
    ///
    /// A deliberate twin of `KSPSwiftCLI`'s `Passes`: SwiftPM forbids depending on an executable
    /// target, and moving it down to `KSPRun` would drag ArgumentParser with it.
    enum StepSkip: String, CaseIterable, Identifiable, Sendable {
        case auto
        case one = "1"
        case two = "2"
        case three = "3"
        case four = "4"

        var id: String { rawValue }
        /// The count, or `nil` for auto -- which is what `ExportRunner.Options` wants for it.
        var passes: Int? { Int(rawValue) }
        var label: String { self == .auto ? "Auto" : rawValue }
    }

    /// Report what would be written, and write nothing.
    var dryRun = false
    /// List every finding rather than one line per kind.
    var verbose = false
    /// How much of the step-skip cycle the export renders. Export-only: an import has no cycle.
    var stepSkip: StepSkip = .auto
    /// How many times the whole export is laid down end to end. Export-only, and not ``stepSkip``:
    /// the device stores no such count, so no repeat of it can be written back.
    var repeatCount = 1
    /// The slots the export runs over, per track, empty meaning all.
    var cells: [Int: Set<Int>] = [:]
    /// Write each selected slot to its own file rather than one file holding all of them. Off is
    /// what the app has always done, and what the CLI does without `--split`.
    var splitPerPattern = false

    /// Export every event at the measured fresh-note velocity instead of the one it stores.
    var replaceVelocity = false
    /// Place every step on a flat grid instead of applying the Pattern's swing. Export-only, and in
    /// the export's sense: on an import, swing means fitting the source's groove instead.
    var replaceSwing = false
    /// Place every step on the grid instead of applying the offset each Note stores.
    var replaceTimeShift = false

    /// What the staged view says is being replaced, shaped like ``GridSelection/exclusionNote``
    /// beside it. Nil when nothing is, so the line is drawn only once there is something to say.
    var replacementNote: String? {
        var parts: [String] = []
        if replaceVelocity { parts.append("velocity with \(MIDIExport.defaultFlatVelocity)") }
        if replaceSwing { parts.append("swing with a flat grid") }
        if replaceTimeShift { parts.append("time shift with a flat grid") }
        return parts.isEmpty ? nil : "Replacing: " + parts.joined(separator: " · ")
    }

    /// This, carrying what the grid ticked. `ConvertRunner`'s `track`/`pattern` are routing, not
    /// selection, so the import mapping is untouched.
    func selecting(_ selection: GridSelection) -> Settings {
        var copy = self
        copy.cells = selection.selectedCells
        return copy
    }

    /// A `.mid` in, a `.KeyStepPro` out.
    func convertOptions(source: URL, output: URL) -> ConvertRunner.Options {
        // `force` stays false: `Naming.vacant` has already found a free path, so the runner's own
        // guard is left in place as a backstop rather than waived.
        ConvertRunner.Options(
            path: source, output: output, dryRun: dryRun, verbose: verbose,
            configPath: drumMapConfigPath)
    }

    /// A `.KeyStepPro` in, a `.mid` out.
    func exportOptions(source: URL, output: URL) -> ExportRunner.Options {
        // Splitting makes `output` the folder the runner fills, which is what `Conversion.plan`
        // hands over: the runner names the files itself, after the source and each slot it found.
        // The three replacements are the runner's own defaults inverted, so all three off asks for
        // what an unset `Options` already carries.
        ExportRunner.Options(
            path: source, output: output, split: splitPerPattern, cells: cells,
            passes: stepSkip.passes, repeatCount: repeatCount,
            flatVelocity: replaceVelocity ? MIDIExport.defaultFlatVelocity : nil,
            applySwing: !replaceSwing, applyTimeShift: !replaceTimeShift, dryRun: dryRun,
            verbose: verbose, configPath: drumMapConfigPath)
    }
}
