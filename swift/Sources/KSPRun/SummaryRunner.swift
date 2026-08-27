import Foundation
import KSPKit
import SwiftMIDIFile

/// Reading a file for a caller that wants to show it rather than convert it.
public enum SummaryRunner {
    public struct Options: Sendable {
        public var path: URL

        public init(path: URL) {
            self.path = path
        }
    }

    /// The summary, or why there is none. `message` carries no `<prog>: ` prefix.
    public struct Result<Summary: Sendable & Hashable>: Sendable, Hashable {
        public var summary: Summary?
        public var message: String?

        public init(summary: Summary? = nil, message: String? = nil) {
            self.summary = summary
            self.message = message
        }
    }

    /// Failure comes back rather than being thrown: a caller needs one `Sendable` value either way.
    public static func run(_ options: Options) -> Result<ProjectSummary> {
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

    public static func song(_ options: Options) -> Result<SongSummary> {
        do {
            let midi = try MusicalMIDI1File(data: Data(contentsOf: options.path))
            return Result(
                summary: try SongSummary(midi, sourceName: options.path.lastPathComponent))
        } catch let error as CocoaError {
            // A read failure's message already names the file.
            return Result(message: error.localizedDescription)
        } catch let error as KSPError {
            // The reader's refusals name what is wrong with the file rather than the file.
            return Result(message: "\(options.path.path): \(error)")
        } catch {
            // Worded as `convert` words it, minus the program name.
            return Result(message: "\(options.path.path): not a readable MIDI file: \(error)")
        }
    }
}
