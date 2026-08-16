import Foundation
import KSPRun

/// What the options sidebar holds, and how it reaches the runners.
///
/// Foundation only -- no SwiftUI -- so the mapping is unit-tested rather than inferred from a
/// window. Every option the app grows is a property here and a line in one of the two mappings
/// below; anything the app does not offer is left off entirely, so it keeps the runner's own
/// default and the app on defaults converts exactly what the CLI on defaults converts.
struct Settings: Sendable, Equatable {
    /// Report what would be written, and write nothing.
    var dryRun = false
    /// List every finding rather than one line per kind. Read by the runner, not just the window:
    /// the runner is what decides how its findings are rendered.
    var verbose = false

    /// A `.mid` in, a `.KeyStepPro` out.
    func convertOptions(source: URL, output: URL) -> ConvertRunner.Options {
        // `force` stays false: `Naming.vacant` already guarantees nothing is there, so the runner's
        // own guard is left in place as a backstop rather than waived.
        ConvertRunner.Options(
            path: source, output: output, dryRun: dryRun, verbose: verbose,
            configPath: drumMapConfigPath)
    }

    /// A `.KeyStepPro` in, a `.mid` out.
    func exportOptions(source: URL, output: URL) -> ExportRunner.Options {
        ExportRunner.Options(
            path: source, output: output, dryRun: dryRun, verbose: verbose,
            configPath: drumMapConfigPath)
    }
}
