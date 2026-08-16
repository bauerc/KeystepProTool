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
        var job: Job
        /// What a dry run said, if one has been made since the name last changed.
        var preview: Outcome?
    }

    var phase: Phase = .idle
    /// What the result will be called. Typed before Convert, so the file is written under it
    /// rather than moved afterwards -- and so the never-overwrite ladder applies to this name.
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
        phase = .staged(Staged(job: job))
    }

    /// Where the staged file would land under the name currently typed. Recomputed as the name is
    /// edited, so the window never promises a path it would not use.
    func plan(for job: Job) -> Conversion.Plan {
        Conversion.plan(job, named: name, into: destination(job))
    }

    /// A dry run describes one name. Editing the name makes it stale, so it is dropped.
    func discardPreview() {
        guard case .staged(var staged) = phase, staged.preview != nil else { return }
        staged.preview = nil
        phase = .staged(staged)
    }

    func convert() async {
        guard let staged else { return }
        // Re-planned rather than reused: a name can be taken between the last keystroke and this.
        let plan = plan(for: staged.job)
        phase = .working(plan.source.lastPathComponent)

        let outcome = await Conversion.run(plan, settings: settings)

        // A dry run wrote nothing, so the file stays staged and can be converted for real.
        guard !outcome.dryRun else {
            phase = .staged(Staged(job: staged.job, preview: outcome))
            return
        }
        if let written = outcome.written { reveal([written]) }
        phase = .done(outcome)
    }

    /// Drop the staged file without writing anything.
    func cancel() { reset() }

    func reset() {
        phase = .idle
        name = ""
    }
}
