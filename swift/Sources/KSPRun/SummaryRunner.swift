import Foundation
import KSPKit

/// Reading a project for a caller that wants to show it rather than convert it.
///
/// The fourth runner, and the one that returns no ``RunResult``: it renders no stdout, no stderr and
/// no exit code, because nothing on either CLI prints a summary. That is deliberate -- a summary
/// adds no text to compare, so the Python needs no mirror of this and the parity scripts have
/// nothing new to check. Adding a subcommand for it would forfeit that and pay full parity.
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
