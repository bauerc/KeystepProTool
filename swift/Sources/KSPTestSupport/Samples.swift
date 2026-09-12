import Foundation
import KSPKit

/// Parsed once each per run; `Project` and `RawProject` are immutable, so sharing is safe.
/// Every sample is addressed by its filename on disk, extension included.
public enum Samples {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var raws: [String: RawProject] = [:]
    private nonisolated(unsafe) static var projects: [String: Project] = [:]
    private nonisolated(unsafe) static var datas: [String: Data] = [:]

    public static let names = [
        "Default.KeyStepPro",
        "baseline.KeyStepPro",
        "initial_project.KeyStepPro",
        "project_5.KeyStepPro",
        "project_9.KeyStepPro",
        "user_empty_project.KeyStepPro",
    ]

    /// MCC's own bytes, as checked in.
    public static func bytes(_ name: String) throws -> Data {
        if let cached = lock.withLock({ datas[name] }) { return cached }
        let data = try Data(contentsOf: RepoData.projectFiles.appending(path: name))
        lock.withLock { datas[name] = data }
        return data
    }

    /// The parsed file, before any decoding.
    public static func raw(_ name: String) throws -> RawProject {
        if let cached = lock.withLock({ raws[name] }) { return cached }
        let raw = try LenientJSON.load(contentsOf: RepoData.projectFiles.appending(path: name))
        lock.withLock { raws[name] = raw }
        return raw
    }

    /// Read without going through `Reader.load`, whose cache `ReadCacheTests` counts.
    public static func project(_ name: String) throws -> Project {
        if let cached = lock.withLock({ projects[name] }) { return cached }
        let project = try Reader.readProject(raw(name), sourceName: name)
        lock.withLock { projects[name] = project }
        return project
    }
}
