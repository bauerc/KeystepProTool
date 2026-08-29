import AppKit
import Foundation
import KSPKit
import Observation

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Phase {
        case idle
        case staged(Staged)
        case working(String)
        case done(Outcome)
    }

    struct Staged {
        var job: Job
        /// What a dry run said, if one has been made since the name last changed.
        var preview: Outcome?
        var summary: SummaryState = .loading
        /// What the import would lay down, replanned whenever the selection or a setting moves.
        var segmentation: SegmentationState = .loading
        var selection = GridSelection()
        var sourceSelection = SourceTrackSelection()
        /// Identity, not path: dropping the same file again is a new drop and needs a new read.
        let id = UUID()

        var blockReason: String? { ticks?.blockReason }

        var exclusionNote: String? { ticks?.exclusionNote }

        /// The tick set this drop seeded; a read that has not landed yet seeded neither.
        private var ticks: (blockReason: String?, exclusionNote: String?)? {
            switch summary {
            case .project: return (selection.blockReason, selection.exclusionNote)
            case .song: return (sourceSelection.blockReason, sourceSelection.exclusionNote)
            case .loading, .failed: return nil
            }
        }
    }

    var phase: Phase = .idle
    var name: String = ""
    /// A preview drawn under the options is stale the moment they are hidden or brought back.
    var mode: Mode {
        get { chosenMode }
        set {
            chosenMode = newValue
            settingsStore.save(newValue)
            discardPreview()
        }
    }
    /// Set through ``choose(_:)`` and ``useDefault(for:)`` alone, so every change is saved.
    private(set) var folders: Folders

    private var chosenMode: Mode
    private var slots: [Job.Kind: Settings]
    /// The direction the panel is showing while nothing is staged, so cancelling a drop does not
    /// snap it to the other one. Within a session only: a launch starts at the import.
    private var lastKind: Job.Kind = .toProject

    private let store: FolderStore
    private let settingsStore: SettingsStore
    private let destination: (Job, Folders) -> Destination
    private let reveal: ([URL]) -> Void
    private let chooseFolder: @MainActor (URL?) -> URL?

    init(
        store: FolderStore = FolderStore(),
        settingsStore: SettingsStore = SettingsStore(),
        destination: @escaping (Job, Folders) -> Destination = AppModel.destination(for:folders:),
        reveal: @escaping ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) },
        chooseFolder: @escaping @MainActor (URL?) -> URL? = AppModel.chooseFolder(startingAt:)
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.destination = destination
        self.reveal = reveal
        self.chooseFolder = chooseFolder
        self.folders = store.load()
        self.chosenMode = settingsStore.loadMode()
        self.slots = Dictionary(
            uniqueKeysWithValues: Job.Kind.allCases.map { ($0, settingsStore.load($0)) })
    }

    /// The direction whose remembered settings the panel is editing.
    var kind: Job.Kind { staged?.job.kind ?? lastKind }

    /// Simple reads as the defaults whatever Advanced holds, which is what keeps a switch to it
    /// from quietly applying options chosen under the other face.
    var settings: Settings {
        get { mode == .simple ? Settings() : slots[kind] ?? Settings() }
        set {
            // Discarded under Simple, which shows no control to write through, and written to
            // whichever slot ``kind`` names now: a write before a drop lands in the other one.
            guard mode == .advanced else { return }
            slots[kind] = newValue
            settingsStore.save(newValue, for: kind)
        }
    }

    nonisolated static func destination(for job: Job, folders: Folders) -> Destination {
        switch job {
        case .toProject: return Destinations.forProjects(chosen: folders[job.folderKind])
        case .toMIDI:
            return Destinations.forMIDI(source: job.source, chosen: folders[job.folderKind])
        }
    }

    var mccWarning: String? { Destinations.mccWarning(for: folders.project) }

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
        lastKind = job.kind
        phase = .staged(Staged(job: job))
    }

    func summarise() async {
        guard let staged, staged.summary == .loading else { return }
        let state = await Conversion.summarise(staged.job)

        // A late answer must not reopen a drop that has since been cancelled or replaced.
        guard case .staged(var current) = phase, current.id == staged.id else { return }
        current.summary = state
        // Each drop kind seeds its own, and leaves the other inert.
        switch state {
        case .project(let summary): current.selection = GridSelection(summary)
        case .song(let summary): current.sourceSelection = SourceTrackSelection(summary)
        case .loading, .failed: break
        }
        phase = .staged(current)
    }

    /// The file and the options the runner will be handed. Keyed on the whole of ``Settings``
    /// rather than the fields a plan reads, so a setting added later cannot be forgotten here.
    struct SegmentationKey: Equatable {
        let drop: UUID
        let settings: Settings
    }

    /// `nil` under Simple, which draws no plan: the key is what the view waits on, so the read
    /// starts of its own accord the moment Advanced is chosen.
    var segmentationKey: SegmentationKey? {
        guard mode == .advanced, let staged, case .toProject = staged.job else { return nil }
        return SegmentationKey(
            drop: staged.id,
            settings: settings.selecting(staged.sourceSelection))
    }

    func segment() async {
        guard let staged, let key = segmentationKey else { return }
        let answer = await Conversion.segment(staged.job, settings: key.settings)

        // A late answer must not overwrite a view whose drop or selection has since moved on --
        // figures for the wrong set of tracks are the one thing a preview must never show.
        guard segmentationKey == key, case .staged(var current) = phase else { return }
        current.segmentation = answer
        phase = .staged(current)
    }

    /// Both selections, or under Simple neither, which is what makes its bytes the CLI's own.
    /// Takes the drop because ``convert()`` has left the staged phase by the time it needs this.
    func conversionSettings(_ staged: Staged) -> Settings {
        guard mode == .advanced else { return Settings() }
        return settings.selecting(staged.selection).selecting(staged.sourceSelection)
    }

    var conversionSettings: Settings { staged.map(conversionSettings) ?? settings }

    func plan(for job: Job) -> Conversion.Plan {
        Conversion.plan(
            job, named: name, into: destination(job, folders),
            splitting: settings.splitPerPattern)
    }

    func toggle(track: Int, pattern: Int) {
        mutate { $0.selection.toggle(track: track, pattern: pattern) }
    }

    func toggle(track: Int) { mutate { $0.selection.toggle(track: track) } }

    func toggle(pattern: Int) { mutate { $0.selection.toggle(pattern: pattern) } }

    func toggle(sourceTrack: Int) { mutate { $0.sourceSelection.toggle(sourceTrack) } }

    func send(sourceTrack: Int, to destination: SourceTrackSelection.Destination) {
        mutate { $0.sourceSelection.send(sourceTrack, to: destination) }
    }

    private func mutate(_ change: (inout Staged) -> Void) {
        guard case .staged(var staged) = phase else { return }
        change(&staged)
        phase = .staged(staged)
        discardPreview()
    }

    var blockReason: String? { staged?.blockReason }

    var exclusionNote: String? { staged?.exclusionNote }

    func discardPreview() {
        guard case .staged(var staged) = phase, staged.preview != nil else { return }
        staged.preview = nil
        phase = .staged(staged)
    }

    func convert() async {
        guard let staged, blockReason == nil else { return }
        // Re-planned rather than reused: a name can be taken between the last keystroke and this.
        let plan = plan(for: staged.job)
        phase = .working(plan.source.lastPathComponent)

        let outcome = await Conversion.run(
            plan, settings: conversionSettings(staged), excluded: staged.exclusionNote)

        guard !outcome.dryRun else {
            var current = staged
            current.preview = outcome
            phase = .staged(current)
            return
        }
        if !outcome.written.isEmpty { reveal(outcome.written) }
        phase = .done(outcome)
    }

    func cancel() { reset() }

    func reset() {
        phase = .idle
        name = ""
    }
}
