import Foundation

/// Which of the two destinations a control refers to. They are set independently: a project and a
/// MIDI file have no reason to land in the same place.
enum FolderKind: String, Sendable, CaseIterable {
    case project
    case midi

    var title: String {
        switch self {
        case .project: return "KeyStep Pro projects"
        case .midi: return "MIDI files"
        }
    }

    /// What the row reads before anything is chosen -- and, being the rule in words, the only place
    /// the shipped behaviour is described to the user.
    var defaultDescription: String {
        switch self {
        case .project: return "MIDI Control Center's Templates folder"
        case .midi: return "Beside the file it came from"
        }
    }
}

/// The folders the user has chosen, if any -- the question ``Destinations`` answers, not its
/// answer: a ``Destination`` is where a file resolved to, notes and all.
///
/// `nil` is not "unset, pending a default": it *is* the default, which is what keeps a user who
/// chooses nothing on the shipped behaviour.
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

    /// Where this kind lands, in words. Abbreviated against the home directory because the sidebar
    /// is narrower than most paths.
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

    /// A remembered folder that has since been deleted or unmounted reverts to the default, rather
    /// than failing every conversion into a path that is no longer there.
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
            // A path, not a security-scoped bookmark: the app is unsandboxed, so there is no scope
            // to restore. `nil` removes the key, so a return to the default is remembered too.
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
