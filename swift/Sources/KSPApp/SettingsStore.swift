import Foundation
import KSPKit

struct SettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadAppearance() -> Appearance {
        defaults.string(forKey: Self.appearanceKey).flatMap(Appearance.init(rawValue:)) ?? .system
    }

    func save(_ appearance: Appearance) {
        defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
    }

    func loadSlot() -> Int {
        let stored = defaults.integer(forKey: Self.slotKey)
        return DeviceRead.slots.contains(stored) ? stored : Sysex.defaultSlot
    }

    func save(slot: Int) {
        defaults.set(slot, forKey: Self.slotKey)
    }

    func loadVerbose() -> Bool {
        defaults.bool(forKey: Self.verboseKey)
    }

    func save(verbose: Bool) {
        defaults.set(verbose, forKey: Self.verboseKey)
    }

    func loadAlsoMidi() -> Bool {
        defaults.bool(forKey: Self.alsoMidiKey)
    }

    func save(alsoMidi: Bool) {
        defaults.set(alsoMidi, forKey: Self.alsoMidiKey)
    }

    func load(_ kind: Job.Kind) -> Settings {
        guard let data = defaults.data(forKey: Self.key(kind)) else { return Settings() }
        return (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
    }

    func save(_ settings: Settings, for kind: Job.Kind) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key(kind))
    }

    private static let appearanceKey = "appearance"
    private static let verboseKey = "verbose"
    private static let slotKey = "device.slot"
    private static let alsoMidiKey = "device.alsoMidi"

    private static func key(_ kind: Job.Kind) -> String { "settings.\(kind.rawValue)" }
}
