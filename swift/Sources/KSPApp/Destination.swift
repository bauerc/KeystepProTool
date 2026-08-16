import Foundation

/// Where a converted file goes, and why.
///
/// Foundation only, and every dependency on the machine is a parameter, so the rules are testable
/// without an MCC install to point at.
struct Destination: Sendable, Hashable {
    let directory: URL
    /// Shown under the result when the file did not land where the user would expect it.
    let note: String?
}

enum Destinations {
    /// MCC's own template folder -- confirmed 2026-08-07 as mode 0777, writable without elevation.
    /// A project has to be here for the Project Browser to list it.
    static let mccTemplates = URL(
        filePath: "/Library/Arturia/MIDI Control Center/Templates/KeyStepPro")

    static var downloads: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    }

    /// Where a converted `.KeyStepPro` belongs.
    ///
    /// The paths and the writability test are injected because the alternative is a test that
    /// passes or fails on whether this machine happens to have MIDI Control Center installed.
    static func forProjects(
        templates: URL = mccTemplates,
        downloads: URL = downloads,
        isWritable: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) }
    ) -> Destination {
        if isWritable(templates) {
            return Destination(directory: templates, note: nil)
        }
        return Destination(
            directory: downloads,
            note: "MIDI Control Center's Templates folder is not writable, so this went to "
                + "Downloads. Move it to \(templates.path) for MCC to list it.")
    }

    /// Where a `.mid` exported from a dropped project belongs: next to the project it came from.
    static func beside(_ source: URL) -> Destination {
        Destination(directory: source.deletingLastPathComponent(), note: nil)
    }
}

/// Naming a converted file. MCC's Project Browser lists the *filename*, so this is what the user
/// sees on the device-facing side and not a cosmetic detail.
enum Naming {
    static let fallbackStem = "Untitled"

    static func stem(of source: URL) -> String {
        sanitised(source.deletingPathExtension().lastPathComponent)
    }

    /// A user-typed name reduced to something a filesystem will take.
    ///
    /// A leading dot is stripped as well as the separators: it is legal, but it would write a file
    /// the user then cannot find in Finder.
    static func sanitised(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallbackStem : name
    }

    /// `directory/stem.ext`, moved along to `stem 2`, `stem 3`, ... until nothing is there.
    ///
    /// The app never overwrites: MCC's folder holds the user's own projects under freely chosen
    /// names, so a clash is as likely to be someone else's work as it is a re-run of this one.
    static func vacant(
        in directory: URL, stem: String, extension ext: String,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let base = sanitised(stem)
        var candidate = directory.appending(path: "\(base).\(ext)")
        var suffix = 2
        while exists(candidate) {
            candidate = directory.appending(path: "\(base) \(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }
}
