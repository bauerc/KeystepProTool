import Foundation
import KSPRun

/// What the options sidebar holds, and how it reaches the runners. No SwiftUI, so it unit-tests.
///
/// An option the sidebar does not offer is left off these mappings entirely, keeping the runner's
/// own default -- which is what makes the app on defaults convert what the CLI on defaults converts.
struct Settings: Sendable, Equatable {
    /// Report what would be written, and write nothing.
    var dryRun = false
    /// List every finding rather than one line per kind.
    var verbose = false

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
            path: source, output: output, dryRun: dryRun, verbose: verbose,
            configPath: drumMapConfigPath)
    }
}
