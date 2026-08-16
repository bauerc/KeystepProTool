import Foundation
import KSPKit

/// What a command body returns. One type for all three runners, so a caller -- the CLI, or M13's
/// app -- writes result handling once instead of once per command.
///
/// `stdout`/`stderr`/`code` are the terminal's view, rendered here so the CLI stays a thin shell
/// and the parity scripts keep comparing text this module produced. `diagnostics` and
/// `destinations`, `message` are the same run said structurally, for a caller that has no terminal:
/// the app lists findings through `Report.render(verbose:)` and reports a failure through `message`
/// rather than re-parsing `stderr`, and reveals what was written rather than re-deriving the
/// destination rule.
public struct RunResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var code: Int32

    /// The findings behind `stderr`, unflattened. Empty when the command reports none.
    public var diagnostics: Report

    /// What the command wrote, in the order written -- or would have written, under a dry run.
    /// Empty for a command that writes nothing, and for any failure.
    public var destinations: [URL]

    /// Why the command failed, without the `<prog>: ` prefix `stderr` carries. `nil` on success.
    public var message: String?

    public init(
        stdout: String = "", stderr: String = "", code: Int32 = 0,
        diagnostics: Report = Report(), destinations: [URL] = [], message: String? = nil
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.code = code
        self.diagnostics = diagnostics
        self.destinations = destinations
        self.message = message
    }

    /// A failure the way every command spells one: `<prog>: <message>` on stderr, non-zero code.
    ///
    /// The prefix, the colon and the trailing newline are part of the byte-for-byte contract with
    /// the Python CLI, so they are written here once rather than at each failure site. A port of
    /// `ksp_cli.reporting.fail`. The unprefixed message is kept for a caller with no terminal.
    /// Public because a usage failure can be spotted in the argument layer, before a runner is
    /// reached -- the same reason `ksp_cli.reporting.fail` is called from the command module.
    public static func failure(_ prog: String, _ message: String, code: Int32) -> RunResult {
        RunResult(stderr: "\(prog): \(message)\n", code: code, message: message)
    }
}
