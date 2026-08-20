import Foundation
import KSPRun

/// What the options sidebar holds, and how it reaches the runners. No SwiftUI, so it unit-tests.
///
/// An option the sidebar does not offer is left off these mappings entirely, keeping the runner's
/// own default -- which is what makes the app on defaults convert what the CLI on defaults converts.
struct Settings: Sendable, Equatable {
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
    /// The slots the export runs over, per track, empty meaning all.
    var cells: [Int: Set<Int>] = [:]

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
        ExportRunner.Options(
            path: source, output: output, cells: cells, passes: stepSkip.passes, dryRun: dryRun,
            verbose: verbose, configPath: drumMapConfigPath)
    }
}
