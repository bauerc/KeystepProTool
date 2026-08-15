import Foundation
import KSPKit

/// The `dump` command's body, split out from its argument parsing so the exit codes and the text
/// are testable without spawning a process -- the same split `main(argv) -> int` gives the Python.
public enum DumpRunner {
    public struct Options: Sendable {
        public var path: URL
        public var showAll = false
        public var track: Int?
        public var pattern: Int?
        public var asJSON = false
        public var drumMapSpec: String?
        public var verbose = false
        public var configPath: URL

        // Spelled out for the same reason as ``ConvertRunner/Options``: a public struct's
        // memberwise initialiser is internal, and every caller is in another module.
        public init(
            path: URL, showAll: Bool = false, track: Int? = nil, pattern: Int? = nil,
            asJSON: Bool = false, drumMapSpec: String? = nil, verbose: Bool = false, configPath: URL
        ) {
            self.path = path
            self.showAll = showAll
            self.track = track
            self.pattern = pattern
            self.asJSON = asJSON
            self.drumMapSpec = drumMapSpec
            self.verbose = verbose
            self.configPath = configPath
        }
    }

    public struct Result: Sendable {
        public var stdout = ""
        public var stderr = ""
        public var code: Int32 = 0
    }

    /// What the user sees this command called, for the message prefix on a failure.
    public static let prog = "ksp-swift-cli dump"

    public static func run(_ options: Options) -> Result {
        let drumMap: DrumMap?
        do {
            drumMap = try resolveDrumMap(options.drumMapSpec, configPath: options.configPath)
        } catch {
            // A bad flag or a malformed config is a usage failure, not a bad file.
            return Result(stderr: "\(prog): drum map: \(error)\n", code: 2)
        }

        let project: Project
        do {
            project = try Reader.load(contentsOf: options.path)
        } catch let error as KSPError {
            return Result(stderr: "\(prog): \(options.path.path): \(error)\n", code: 1)
        } catch {
            // Its message already names the file.
            return Result(stderr: "\(prog): \(error.localizedDescription)\n", code: 1)
        }

        let selected = project.select(track: options.track, pattern: options.pattern)
        let text =
            options.asJSON
            ? selected.toJSON(drumMap: drumMap).serialised()
            : formatProject(
                selected, showAll: options.showAll, drumMap: drumMap, verbose: options.verbose)
        return Result(stdout: text)
    }
}
