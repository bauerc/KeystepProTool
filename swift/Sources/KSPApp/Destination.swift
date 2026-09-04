import Foundation

struct Destination: Sendable, Hashable {
    let directory: URL
    /// Shown under the result when the file did not land where the user would expect it.
    let note: String?
}

enum Destinations {
    /// A project has to be here for MCC's Project Browser to list it.
    static let mccTemplates = URL(
        filePath: "/Library/Arturia/MIDI Control Center/Templates/KeyStepPro")

    static var downloads: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    }

    static func forProjects(
        chosen: URL? = nil,
        templates: URL = mccTemplates,
        downloads: URL = downloads,
        isWritable: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) }
    ) -> Destination {
        if let chosen { return Destination(directory: chosen, note: nil) }
        if isWritable(templates) {
            return Destination(directory: templates, note: nil)
        }
        return Destination(
            directory: downloads,
            note: "MIDI Control Center's Templates folder is not writable, so this went to "
                + "Downloads. Move it to \(templates.path) for MCC to list it.")
    }

    static func forMIDI(source: URL, chosen: URL?) -> Destination {
        Destination(directory: chosen ?? source.deletingLastPathComponent(), note: nil)
    }

    static func mccWarning(for chosen: URL?, templates: URL = mccTemplates) -> String? {
        guard let chosen, folderPath(chosen) != folderPath(templates) else { return nil }
        return "MIDI Control Center's Project Browser lists only its own Templates folder, so it "
            + "will not show a project written here."
    }

    /// Symlinks are resolved and a trailing slash dropped, so two spellings compare equal.
    private static func folderPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// MCC's Project Browser lists the *filename*, so a name is device-facing, not cosmetic.
enum Naming {
    static let fallbackStem = "Untitled"

    static func stem(of source: URL) -> String {
        sanitised(source.deletingPathExtension().lastPathComponent)
    }

    /// A leading dot is stripped too: legal, but it writes a file Finder will not show.
    static func sanitised(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallbackStem : name
    }

    /// `stem`, moved along to `stem 2`, `stem 3`, ... until every suffix named is free. A read
    /// writing two files needs one stem that suits both, not a free name per file.
    static func vacantStem(
        in directory: URL, stem: String, suffixes: [String],
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> String {
        let base = sanitised(stem)
        var candidate = base
        var attempt = 2
        while suffixes.contains(where: { exists(directory.appending(path: candidate + $0)) }) {
            candidate = "\(base) \(attempt)"
            attempt += 1
        }
        return candidate
    }

    /// `directory/stem.ext`, moved along to `stem 2`, `stem 3`, ... until nothing is there.
    static func vacant(
        in directory: URL, stem: String, extension ext: String,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        firstFree(in: directory, stem: stem, extension: ext, exists: exists)
    }

    static func vacantFolder(
        in directory: URL, stem: String,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        firstFree(in: directory, stem: stem, extension: nil, exists: exists)
    }

    private static func firstFree(
        in directory: URL, stem: String, extension ext: String?, exists: (URL) -> Bool
    ) -> URL {
        let tail = ext.map { ".\($0)" } ?? ""
        let free = vacantStem(in: directory, stem: stem, suffixes: [tail], exists: exists)
        return directory.appending(path: "\(free)\(tail)")
    }
}
