import Foundation

/// Where the shipped template sits relative to a running binary.
///
/// `Bundle.module` looks only beside `Bundle.main.bundleURL`, which for anything inside a `.app`
/// is the bundle root rather than `Contents/Resources` -- and for a binary reached through a
/// symlink it is the directory the link sits in. Both miss, leaving only the hard-coded build
/// directory the package was compiled in, so a copy on another machine would trap.
enum TemplateLocation {
    static let resourceName = "Default"
    static let resourceExtension = "KeyStepPro"

    /// Directories that may hold the resource bundle, nearest first.
    static func searchRoots(forExecutableAt executable: URL) -> [URL] {
        // The link itself tells you nothing about where the resources are; the file it points at
        // does.
        let real = executable.resolvingSymlinksInPath()
        let directory = real.deletingLastPathComponent()
        var roots = [directory]
        if directory.lastPathComponent == "MacOS" {
            roots.append(directory.deletingLastPathComponent().appending(path: "Resources"))
        }
        return roots
    }

    /// Globbed rather than named, so renaming the package cannot quietly ship a binary that runs
    /// and then cannot find its template.
    static func find(
        forExecutableAt executable: URL, in fileManager: FileManager = .default
    ) -> URL? {
        let file = "\(resourceName).\(resourceExtension)"
        for root in searchRoots(forExecutableAt: executable) {
            let bundles =
                (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "bundle" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            for bundle in bundles {
                for candidate in [
                    bundle.appending(path: file),
                    bundle.appending(path: "Contents/Resources/\(file)"),
                ] where fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}
