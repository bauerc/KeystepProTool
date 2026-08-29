import Foundation

/// Which face the app shows. Simple is the app as it shipped: drop, name, convert on defaults.
enum Mode: String, CaseIterable, Identifiable, Sendable {
    case simple
    case advanced

    var id: String { rawValue }

    var label: String {
        switch self {
        case .simple: return "Simple"
        case .advanced: return "Advanced"
        }
    }
}

/// The mode and one ``Settings`` per direction, remembered between launches.
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

    private static func key(_ kind: Job.Kind) -> String { "settings.\(kind.rawValue)" }
}
