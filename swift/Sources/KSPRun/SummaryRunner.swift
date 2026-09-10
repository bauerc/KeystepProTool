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

    /// Why a file did not summarise, classified rather than only worded: a caller that shows the
    /// failure to someone has to say something different for each of these.
    public struct Failure: Sendable, Hashable {
        public enum Reason: Sendable, Hashable {
            /// The bytes never arrived: moved, renamed, or unreadable.
            case unopenable
            /// Opened, and is not the format its extension claims.
            case unrecognised
            /// Parsed, and refused by the reader in the reader's own words.
            case refused
        }

        public let reason: Reason
        public let path: URL
        /// The error as its own type spells it, which is a log's line rather than a window's.
        public let detail: String

        public init(_ reason: Reason, at path: URL, detail: String) {
            self.reason = reason
            self.path = path
            self.detail = detail
        }

        /// Worded as `dump` words it, minus the program name.
        public var message: String { "\(path.path): \(detail)" }
    }

    /// Failure comes back rather than being thrown: a caller needs one `Sendable` value either way.
    public enum Result<Summary: Sendable & Hashable>: Sendable, Hashable {
        case read(Summary)
        case failed(Failure)

        public var summary: Summary? {
            guard case .read(let summary) = self else { return nil }
            return summary
        }

        public var failure: Failure? {
            guard case .failed(let failure) = self else { return nil }
            return failure
        }

        /// `nil` on a summary. Carries no `<prog>: ` prefix.
        public var message: String? { failure?.message }
    }

    public static func run(_ options: Options) -> Result<ProjectSummary> {
        do {
            return .read(ProjectSummary(try Reader.load(contentsOf: options.path)))
        } catch let error as KSPError {
            // Everything the reader refuses here is the format itself: a project that parses at
            // all summarises, so there is no third case to tell apart.
            return .failed(Failure(.unrecognised, at: options.path, detail: "\(error)"))
        } catch {
            return .failed(
                Failure(.unopenable, at: options.path, detail: error.localizedDescription))
        }
    }

    public static func song(_ options: Options) -> Result<SongSummary> {
        do {
            let midi = try MusicalMIDI1File(data: Data(contentsOf: options.path))
            return .read(try SongSummary(midi, sourceName: options.path.lastPathComponent))
        } catch let error as CocoaError {
            return .failed(
                Failure(.unopenable, at: options.path, detail: error.localizedDescription))
        } catch let error as KSPError {
            // The reader's refusals name what is wrong with the file rather than the file.
            return .failed(Failure(.refused, at: options.path, detail: "\(error)"))
        } catch {
            return .failed(Failure(.unrecognised, at: options.path, detail: "\(error)"))
        }
    }
}
