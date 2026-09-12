import Foundation

/// `Bundle.module` looks only beside `Bundle.main.bundleURL`, which misses inside a `.app` and
/// through a symlink, leaving the build directory the package was compiled in.
enum TemplateLocation {
    static let resourceName = "Default"
    static let resourceExtension = "KeyStepPro"

    static func searchRoots(forExecutableAt executable: URL) -> [URL] {
        // The link tells you nothing about where the resources are; the file it points at does.
        let real = executable.resolvingSymlinksInPath()
        let directory = real.deletingLastPathComponent()
        var roots = [directory]
        if directory.lastPathComponent == "MacOS" {
            roots.append(directory.deletingLastPathComponent().appending(path: "Resources"))
        }
        return roots
    }

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
