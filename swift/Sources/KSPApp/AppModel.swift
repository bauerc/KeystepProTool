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
        /// What was dropped, read for showing rather than converting. Only a project has one.
        var summary: SummaryState = .absent
        /// This drop, as distinct from the one before it. The view keys its read off this rather
        /// than off the path, because dropping the same file again is a new drop and needs a new
        /// read -- the path alone would leave the second one waiting forever.
        let id = UUID()
    }

    var phase: Phase = .idle
    /// What the result will be called. Typed before Convert, so the file is written under it
    /// rather than moved afterwards -- and so the never-overwrite ladder applies to this name.
    var name: String = ""
    var settings = Settings()
    /// Set through ``choose(_:)`` and ``useDefault(for:)`` alone, so every change is saved.
    private(set) var folders: Folders

    // Injected: the alternative is a test that writes into MCC's Templates folder, opens Finder and
    // puts a modal panel on screen.
    private let store: FolderStore
    private let destination: (Job, Folders) -> Destination
    private let reveal: ([URL]) -> Void
    /// Main-actor by type, not by convention: it puts a modal panel on screen.
    private let chooseFolder: @MainActor (URL?) -> URL?

    init(
        store: FolderStore = FolderStore(),
        destination: @escaping (Job, Folders) -> Destination = AppModel.destination(for:folders:),
        reveal: @escaping ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) },
        chooseFolder: @escaping @MainActor (URL?) -> URL? = AppModel.chooseFolder(startingAt:)
    ) {
        self.store = store
        self.destination = destination
        self.reveal = reveal
        self.chooseFolder = chooseFolder
        self.folders = store.load()
    }

    /// A project lands where MCC will list it; a MIDI file lands beside what it came from -- unless
    /// the user has said otherwise, for either one on its own.
    nonisolated static func destination(for job: Job, folders: Folders) -> Destination {
        switch job {
        case .toProject: return Destinations.forProjects(chosen: folders.project)
        case .toMIDI: return Destinations.forMIDI(source: job.source, chosen: folders.midi)
        }
    }

    /// The one thing a chosen project folder costs. Shown while the folder is set, not once.
    var mccWarning: String? { Destinations.mccWarning(for: folders.project) }

    /// Cancelling the panel leaves the folder as it was.
    func choose(_ kind: FolderKind) {
        guard let picked = chooseFolder(folders[kind]) else { return }
        folders[kind] = picked
        store.save(folders)
    }

    func useDefault(for kind: FolderKind) {
        folders[kind] = nil
        store.save(folders)
    }

    @MainActor
    private static func chooseFolder(startingAt current: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = current
        return panel.runModal() == .OK ? panel.url : nil
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
                    written: [],
                    headline: "\(url.lastPathComponent) is not a MIDI file or a KeyStep Pro "
                        + "project.", report: Report(), note: nil))
            return
        }
        name = Naming.stem(of: url)
        // A project is read for the staged view; a MIDI file has nothing to read yet (#145).
        phase = .staged(Staged(job: job, summary: job.isProject ? .loading : .absent))
    }

    /// Read the staged project, for the staged view to show what is in it before Convert is pressed.
    ///
    /// Awaitable rather than started from ``accept(_:)``: the view drives it from `.task`, and a
    /// test can drive it without a window. Once a summary has landed a further call costs nothing;
    /// one made while a read is still in flight does start a second read, and deliberately so --
    /// that is how a result thrown away below is asked for again.
    func summarise() async {
        guard let staged, staged.job.isProject, staged.summary == .loading else { return }
        let state = await Conversion.summarise(staged.job.source)

        // The drop can be cancelled, converted or replaced while the read is in flight, and a late
        // answer must not reopen a window that has moved on. Thrown away rather than held: the view
        // asks again when it comes back to a summary still waiting.
        guard case .staged(var current) = phase, current.id == staged.id else { return }
        current.summary = state
        phase = .staged(current)
    }

    /// Where the staged file would land under the name currently typed. Recomputed as the name is
    /// edited, so the window never promises a path it would not use.
    func plan(for job: Job) -> Conversion.Plan {
        Conversion.plan(job, named: name, into: destination(job, folders))
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

        // A dry run wrote nothing, so the file stays staged and can be converted for real. The same
        // drop rather than a new one: it is still the file that was dropped, summary and all.
        guard !outcome.dryRun else {
            var current = staged
            current.preview = outcome
            phase = .staged(current)
            return
        }
        if !outcome.written.isEmpty { reveal(outcome.written) }
        phase = .done(outcome)
    }

    /// Drop the staged file without writing anything.
    func cancel() { reset() }

    func reset() {
        phase = .idle
        name = ""
    }
}
