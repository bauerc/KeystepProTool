import Foundation
import KSPKit

/// The unit the app dresses as, how much of a finding list it prints, and one ``Settings`` per
/// direction, all remembered between launches.
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

    /// The project the device read last took. A stored number outside the device's sixteen -- a
    /// hand-edited preference, or a build that numbered them differently -- reads as the first.
    func loadSlot() -> Int {
        let stored = defaults.integer(forKey: Self.slotKey)
        return DeviceRead.slots.contains(stored) ? stored : Sysex.defaultSlot
    }

    func save(slot: Int) {
        defaults.set(slot, forKey: Self.slotKey)
    }

    /// A preference rather than a conversion option: it changes how many rows a finding list
    /// draws, not what is written, so it belongs to the app rather than to either direction.
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

    /// A blob an earlier build wrote differently reads as the defaults rather than throwing.
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
