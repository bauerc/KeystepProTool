import Foundation
import KSPKit

public enum DumpRunner {
    public struct Options: Sendable {
        public var path: URL
        public var showAll: Bool
        public var tracks: Set<Int>
        public var patterns: Set<Int>
        public var asJSON: Bool
        public var drumMapSpec: String?
        public var verbose: Bool
        public var configPath: URL

        // Spelled out because a public struct's memberwise initialiser is internal.
        public init(
            path: URL, showAll: Bool = false, tracks: Set<Int> = [], patterns: Set<Int> = [],
            asJSON: Bool = false, drumMapSpec: String? = nil, verbose: Bool = false, configPath: URL
        ) {
            self.path = path
            self.showAll = showAll
            self.tracks = tracks
            self.patterns = patterns
            self.asJSON = asJSON
            self.drumMapSpec = drumMapSpec
            self.verbose = verbose
            self.configPath = configPath
        }
    }

    public static let prog = "ksp-swift-cli dump"

    static func fail(_ message: String, code: Int32) -> RunResult {
        .failure(prog, message, code: code)
    }

    public static func run(_ options: Options) -> RunResult {
        let drumMap: DrumMap?
        do {
            drumMap = try resolveDrumMap(options.drumMapSpec, configPath: options.configPath)
        } catch {
            // A bad flag or a malformed config is a usage failure, not a bad file.
            return fail("drum map: \(error)", code: 2)
        }

        let project: Project
        do {
            project = try Reader.load(contentsOf: options.path)
        } catch let error as KSPError {
            return fail("\(options.path.path): \(error)", code: 1)
        } catch {
            // Its message already names the file.
            return fail("\(error.localizedDescription)", code: 1)
        }

        let selected = project.select(tracks: options.tracks, patterns: options.patterns)
        let text =
            options.asJSON
            ? selected.toJSON(drumMap: drumMap).serialised()
            : formatProject(
                selected, showAll: options.showAll, drumMap: drumMap, verbose: options.verbose)
        return RunResult(stdout: text)
    }
}
