import AppKit
import Foundation
import KSPKit
import Observation

/// The window's state. The one place in the app that is mutable, and it is main-actor confined --
/// everything below it is a value type the runners already declare `Sendable`.
///
/// No SwiftUI here: the phases, the settings and the two machine-facing dependencies are all
/// testable without a window, which is what `AppModelTests` does.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Phase {
        case idle
        /// Dropped, understood, and waiting for Convert. Nothing has been written.
        case staged(Staged)
        case working(String)
        case done(Outcome)
    }

    /// A drop the window is holding: what it would do, and what the last dry run said about it.
    struct Staged {
        var plan: Conversion.Plan
        /// The result of a dry run of this very plan, which leaves the file staged so the user can
        /// switch Dry run off and press Convert again.
        var preview: Outcome?
    }

    var phase: Phase = .idle
    var name: String = ""
    var settings = Settings()

    /// Where each direction's result goes, and how a written file is shown to the user. Injected
    /// because the alternative is a test that writes into MIDI Control Center's Templates folder
    /// and opens Finder windows.
    private let destination: (Job) -> Destination
    private let reveal: ([URL]) -> Void

    init(
        destination: @escaping (Job) -> Destination = AppModel.destination(for:),
        reveal: @escaping ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    ) {
        self.destination = destination
        self.reveal = reveal
    }

    /// A `.KeyStepPro` lands where MCC will list it; a `.mid` lands beside the project it came from.
    nonisolated static func destination(for job: Job) -> Destination {
        switch job {
        case .toProject: return Destinations.forProjects()
        case .toMIDI: return Destinations.beside(job.source)
        }
    }

    var staged: Staged? {
        guard case .staged(let staged) = phase else { return nil }
        return staged
    }

    /// Hold a dropped file. Nothing is written until ``convert()``.
    func accept(_ url: URL) {
        guard let job = Conversion.job(for: url) else {
            phase = .done(
                Outcome(
                    written: nil,
                    headline: "\(url.lastPathComponent) is not a MIDI file or a KeyStep Pro "
                        + "project.", report: Report(), note: nil))
            return
        }
        name = Naming.stem(of: url)
        phase = .staged(Staged(plan: plan(for: job)))
    }

    /// Run the staged conversion.
    ///
    /// The plan is recomputed here rather than reused: a name can be taken between the drop and the
    /// press, and the window would otherwise promise a path the runner then refuses.
    func convert() async {
        guard let staged else { return }
        let plan = plan(for: staged.plan.job)
        phase = .working(plan.source.lastPathComponent)

        let outcome = await Conversion.run(plan, settings: settings)

        // A dry run wrote nothing, so the file stays staged: switch the toggle off, press Convert
        // again, and it is written for real.
        guard !outcome.dryRun else {
            phase = .staged(Staged(plan: plan, preview: outcome))
            return
        }
        if let written = outcome.written {
            name = written.deletingPathExtension().lastPathComponent
            reveal([written])
        }
        phase = .done(outcome)
    }

    /// Drop the staged file without writing anything.
    func cancel() {
        reset()
    }

    /// Rename what was just written, in place. MCC's Project Browser lists the filename, so this
    /// is how a project gets the name it will carry on the device.
    func renameResult() {
        guard case .done(var outcome) = phase, outcome.wroteFile, let written = outcome.written
        else { return }
        do {
            let moved = try Naming.rename(written, toStem: name)
            outcome.written = moved
            outcome.note = nil
            name = moved.deletingPathExtension().lastPathComponent
            phase = .done(outcome)
            reveal([moved])
        } catch {
            outcome.note = "Could not rename: \(error.localizedDescription)"
            phase = .done(outcome)
        }
    }

    func reset() {
        phase = .idle
        name = ""
    }

    private func plan(for job: Job) -> Conversion.Plan {
        Conversion.plan(job, named: Naming.stem(of: job.source), into: destination(job))
    }
}
