import Foundation
import KSPKit
import SwiftMIDIFile

public enum SummaryRunner {
    public struct Options: Sendable {
        public var path: URL

        public init(path: URL) {
            self.path = path
        }
    }

    public struct Failure: Sendable, Hashable {
        public enum Reason: Sendable, Hashable {
            case unopenable
            case unrecognised
            case refused
        }

        public let reason: Reason
        public let path: URL
        public let detail: String

        public init(_ reason: Reason, at path: URL, detail: String) {
            self.reason = reason
            self.path = path
            self.detail = detail
        }

        public var message: String { "\(path.path): \(detail)" }
    }

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

        public var message: String? { failure?.message }
    }

    public static func run(_ options: Options) -> Result<ProjectSummary> {
        do {
            return .read(ProjectSummary(try Reader.load(contentsOf: options.path)))
        } catch let error as KSPError {
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
            return .failed(Failure(.refused, at: options.path, detail: "\(error)"))
        } catch {
            return .failed(Failure(.unrecognised, at: options.path, detail: "\(error)"))
        }
    }
}
