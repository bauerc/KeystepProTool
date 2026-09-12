import Foundation
import KSPKit
import KSPRun

enum DeviceRead {
    struct Plan: Sendable, Hashable {
        let slot: Int
        let target: URL
        let alsoMidi: Bool
        let note: String?
    }

    static let slots = 1...Constants.projectSlots

    static func defaultStem(slot: Int) -> String { "Project \(slot)" }

    static let direction = "KeyStep Pro → project file"

    static func plan(
        slot: Int, named typed: String, into destination: Destination, alsoMidi: Bool,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Plan {
        let base = Naming.sanitised(typed.isEmpty ? defaultStem(slot: slot) : typed)
        let stem = Naming.vacantStem(
            in: destination.directory, stem: base,
            suffixes: alsoMidi ? [".KeyStepPro", ".mid"] : [".KeyStepPro"], exists: exists)
        let target = destination.directory.appending(path: "\(stem).KeyStepPro")
        let note = [destination.note, stem == base ? nil : Conversion.collisionNote(target)]
            .compactMap { $0 }.joined(separator: " ")
        return Plan(
            slot: slot, target: target, alsoMidi: alsoMidi, note: note.isEmpty ? nil : note)
    }

    static func options(_ plan: Plan, verbose: Bool) -> PullRunner.Options {
        PullRunner.Options(
            output: plan.target, slot: plan.slot, alsoMidi: plan.alsoMidi, verbose: verbose,
            configPath: drumMapConfigPath)
    }

    static func run(
        _ plan: Plan, verbose: Bool, pull: @escaping @Sendable (PullRunner.Options) -> RunResult
    ) async -> Outcome {
        let options = options(plan, verbose: verbose)
        let result = await Task.detached(priority: .userInitiated) { pull(options) }.value
        var made = outcome(from: result, note: plan.note)
        made.document = "Project \(plan.slot)"
        made.direction = direction
        return made
    }

    static func outcome(from result: RunResult, note: String?) -> Outcome {
        guard !result.destinations.isEmpty else {
            return Outcome(
                written: [], headline: result.message ?? "The read failed.",
                report: result.diagnostics, note: nil, source: .deviceRead)
        }
        return Outcome(
            written: result.destinations, headline: result.message ?? summary(result),
            report: result.diagnostics, note: note, source: .deviceRead)
    }

    static func summary(_ result: RunResult) -> String {
        let kept = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("wrote ") }
        return kept.isEmpty ? "Read." : kept.joined(separator: "\n")
    }
}
