import Foundation
import KSPKit

/// Reading a project for a caller that wants to show it rather than convert it.
///
/// The one runner that returns no ``RunResult``: nothing on either CLI prints a summary, so there
/// is no stdout, stderr or exit code to render. See `CLAUDE.md` for why that exemption matters.
public enum SummaryRunner {
    public struct Options: Sendable {
        public var path: URL

        public init(path: URL) {
            self.path = path
        }
    }

    /// The summary, or why there is none. `message` carries no `<prog>: ` prefix, the same way
    /// ``RunResult/message`` does not -- there is no terminal here to write one for.
    public struct Result: Sendable, Hashable {
        public var summary: ProjectSummary?
        public var message: String?

        public init(summary: ProjectSummary? = nil, message: String? = nil) {
            self.summary = summary
            self.message = message
        }
    }

    /// Failure comes back rather than being thrown: the app calls this from a `Task.detached` and
    /// needs one `Sendable` value either way, and an unreadable drop is something to show in the
    /// window rather than an exit code.
    public static func run(_ options: Options) -> Result {
        do {
            return Result(summary: ProjectSummary(try Reader.load(contentsOf: options.path)))
        } catch let error as KSPError {
            // Worded as `dump` words it, minus the program name.
            return Result(message: "\(options.path.path): \(error)")
        } catch {
            // Its message already names the file.
            return Result(message: error.localizedDescription)
        }
    }
}
