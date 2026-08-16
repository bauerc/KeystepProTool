import AppKit
import Foundation
import KSPKit
import Observation

/// The window's state, main-actor confined. No SwiftUI, so the phases test without a window.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Phase {
        case idle
        /// Dropped and waiting for Convert. Nothing has been written.
        case staged(Staged)
        case working(String)
        case done(Outcome)
    }

    struct Staged {
        var plan: Conversion.Plan
        /// What a dry run of this plan said, if one has been made.
        var preview: Outcome?
    }

    var phase: Phase = .idle
    var name: String = ""
    var settings = Settings()

    // Injected: the alternative is a test that writes into MCC's Templates folder and opens Finder.
    private let destination: (Job) -> Destination
    private let reveal: ([URL]) -> Void

    init(
        destination: @escaping (Job) -> Destination = AppModel.destination(for:),
        reveal: @escaping ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    ) {
        self.destination = destination
        self.reveal = reveal
    }

    /// A project lands where MCC will list it; a MIDI file lands beside what it came from.
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

    func convert() async {
        guard let staged else { return }
        // Re-planned rather than reused: a name can be taken between the drop and the press.
        let plan = plan(for: staged.plan.job)
        phase = .working(plan.source.lastPathComponent)

        let outcome = await Conversion.run(plan, settings: settings)

        // A dry run wrote nothing, so the file stays staged and can be converted for real.
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
    func cancel() { reset() }

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
