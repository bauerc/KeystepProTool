import Foundation
import KSPKit
import KSPRun

/// Reading a project off the attached device. The app owns which project, where the files go and
/// what they are called; ``PullRunner`` owns everything from the first frame to the last byte.
enum DeviceRead {
    /// What the read will do, resolved fresh the moment Read is pressed: a name can be taken
    /// between the last keystroke and the first frame.
    struct Plan: Sendable, Hashable {
        let slot: Int
        /// The `.KeyStepPro`. The `.mid`, where it was asked for, is written beside it.
        let target: URL
        let alsoMidi: Bool
        let note: String?
    }

    /// The device's sixteen, numbered as it numbers them.
    static let slots = 1...Constants.projectSlots

    static func defaultStem(slot: Int) -> String { "Project \(slot)" }

    static func plan(
        slot: Int, named typed: String, into destination: Destination, alsoMidi: Bool,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Plan {
        let base = Naming.sanitised(typed.isEmpty ? defaultStem(slot: slot) : typed)
        // Both suffixes at once: the runner refuses the whole read when either file is already
        // there, so a free `.KeyStepPro` beside a taken `.mid` is not a free name.
        let stem = Naming.vacantStem(
            in: destination.directory, stem: base,
            suffixes: alsoMidi ? [".KeyStepPro", ".mid"] : [".KeyStepPro"], exists: exists)
        let target = destination.directory.appending(path: "\(stem).KeyStepPro")
        let note = [destination.note, stem == base ? nil : Conversion.collisionNote(target)]
            .compactMap { $0 }.joined(separator: " ")
        return Plan(
            slot: slot, target: target, alsoMidi: alsoMidi, note: note.isEmpty ? nil : note)
    }

    /// What `ksp-swift-cli pull` would be run with. `force` stays false for the reason a
    /// conversion's does: a free name was found, so the runner's guard is a backstop.
    static func options(_ plan: Plan, verbose: Bool) -> PullRunner.Options {
        PullRunner.Options(
            output: plan.target, slot: plan.slot, alsoMidi: plan.alsoMidi, verbose: verbose,
            configPath: drumMapConfigPath)
    }

    static func run(
        _ plan: Plan, verbose: Bool, pull: @escaping @Sendable (PullRunner.Options) -> RunResult
    ) async -> Outcome {
        let options = options(plan, verbose: verbose)
        // Detached for the reason a conversion is, and more so: this one is seconds at the device,
        // and the window has to keep drawing throughout.
        let result = await Task.detached(priority: .userInitiated) { pull(options) }.value
        return outcome(from: result, note: plan.note)
    }

    /// A failure keeps the runner's own words: they name the fix -- the cable, MIDI Control Center,
    /// `killall MIDIServer`, a slot with nothing saved in it -- and a second phrasing would not.
    static func outcome(from result: RunResult, note: String?) -> Outcome {
        guard result.code == 0, !result.destinations.isEmpty else {
            return Outcome(
                written: [], headline: result.message ?? "The read failed.",
                report: result.diagnostics, note: nil, source: .deviceRead)
        }
        return Outcome(
            written: result.destinations, headline: summary(result), report: result.diagnostics,
            note: note, source: .deviceRead)
    }

    /// The runner's summary, minus the paths it wrote -- which the window lists for itself. What
    /// is left is what the read cost and what came back.
    static func summary(_ result: RunResult) -> String {
        let kept = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("wrote ") }
        return kept.isEmpty ? "Read." : kept.joined(separator: "\n")
    }
}
