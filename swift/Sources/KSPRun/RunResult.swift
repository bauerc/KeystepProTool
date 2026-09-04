import Foundation
import KSPKit

public struct RunResult: Sendable {
    public var stdout: String
    public var stderr: String
    public var code: Int32

    public var diagnostics: Report

    /// What the command wrote, or would have written under a dry run. A failure names what it
    /// had already written, and is empty only where nothing reached disk.
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
    public static func failure(_ prog: String, _ message: String, code: Int32) -> RunResult {
        RunResult(stderr: "\(prog): \(message)\n", code: code, message: message)
    }
}
