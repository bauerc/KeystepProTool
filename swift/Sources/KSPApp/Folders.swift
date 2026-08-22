import Foundation

enum FolderKind: String, Sendable, CaseIterable {
    case project
    case midi

    var title: String {
        switch self {
        case .project: return "KeyStep Pro projects"
        case .midi: return "MIDI files"
        }
    }

    /// What the row reads before anything is chosen.
    var defaultDescription: String {
        switch self {
        case .project: return "MIDI Control Center's Templates folder"
        case .midi: return "Beside the file it came from"
        }
    }
}

/// The folders the user has chosen. `nil` is not "unset, pending a default": it *is* the default.
struct Folders: Sendable, Equatable {
    var project: URL?
    var midi: URL?

    subscript(kind: FolderKind) -> URL? {
        get {
            switch kind {
            case .project: return project
            case .midi: return midi
            }
        }
        set {
            switch kind {
            case .project: project = newValue
            case .midi: midi = newValue
            }
        }
    }

    func description(of kind: FolderKind) -> String {
        guard let url = self[kind] else { return kind.defaultDescription }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// The chosen folders, remembered between launches.
struct FolderStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A remembered folder that has since gone away reverts to the default.
    func load(directoryExists: (URL) -> Bool = FolderStore.directoryExists) -> Folders {
        var folders = Folders()
        for kind in FolderKind.allCases {
            guard let path = defaults.string(forKey: Self.key(kind)) else { continue }
            let url = URL(filePath: path)
            if directoryExists(url) { folders[kind] = url }
        }
        return folders
    }

    func save(_ folders: Folders) {
        for kind in FolderKind.allCases {
            // A path, not a bookmark: the app is unsandboxed. `nil` removes the key.
            defaults.set(folders[kind]?.path, forKey: Self.key(kind))
        }
    }

    private static func key(_ kind: FolderKind) -> String { "destination.\(kind.rawValue)" }

    static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let present = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return present && isDirectory.boolValue
    }
}
