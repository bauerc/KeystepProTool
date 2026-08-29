import Foundation

/// The face the app opens on, the unit it dresses as, and one ``Settings`` per direction, all
/// remembered between launches.
struct SettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadMode() -> Mode {
        defaults.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:)) ?? .simple
    }

    func save(_ mode: Mode) {
        defaults.set(mode.rawValue, forKey: Self.modeKey)
    }

    func loadAppearance() -> Appearance {
        defaults.string(forKey: Self.appearanceKey).flatMap(Appearance.init(rawValue:)) ?? .system
    }

    func save(_ appearance: Appearance) {
        defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
    }

    /// A blob an earlier build wrote differently reads as the defaults rather than throwing.
    func load(_ kind: Job.Kind) -> Settings {
        guard let data = defaults.data(forKey: Self.key(kind)) else { return Settings() }
        return (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
    }

    func save(_ settings: Settings, for kind: Job.Kind) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key(kind))
    }

    private static let modeKey = "mode"
    private static let appearanceKey = "appearance"

    private static func key(_ kind: Job.Kind) -> String { "settings.\(kind.rawValue)" }
}
