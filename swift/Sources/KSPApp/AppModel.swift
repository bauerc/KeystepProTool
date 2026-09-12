import AppKit
import Foundation
import KSPKit
import KSPRun
import Observation

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Phase {
        case idle
        case staged(Staged)
        case working(String)
        case reading(Int)
        case done(Outcome)
    }

    struct Staged {
        var job: Job
        var preview: Outcome?
        var summary: SummaryState = .loading
        var segmentation: SegmentationState = .loading
        var arrangement: ArrangementState = .loading
        var selection = GridSelection()
        var sourceSelection = SourceTrackSelection()
        let id = UUID()

        func blockReason(_ settings: Settings) -> String? {
            switch summary {
            case .project: return selection.blockReason
            case .song:
                return sourceSelection.blockReason(
                    settings.drumSense(named: sourceSelection.drumTrack))
            case .failed(let failure): return failure.blockReason
            case .loading: return nil
            }
        }

        var isUnreadable: Bool {
            if case .failed = summary { return true }
            return false
        }

        var exclusionNote: String? {
            switch summary {
            case .project: return selection.exclusionNote
            case .song: return sourceSelection.exclusionNote
            case .loading, .failed: return nil
            }
        }
    }

    struct ReadPreview: Equatable {
        let project: URL
        var summary: SummaryState = .loading
        var arrangement: ArrangementState = .loading
    }

    enum DrumChoice: Hashable, Identifiable, Sendable {
        case automatic
        case source(Int)
        case none

        var id: Self { self }

        var label: String {
            switch self {
            case .automatic: return Settings.Drums.automatic.label
            case .source(let number): return "Source track \(number)"
            case .none: return Settings.Drums.none.label
            }
        }
    }

    var phase: Phase = .idle
    var name: String = ""
    var appearance: Appearance {
        get { chosenAppearance }
        set {
            chosenAppearance = newValue
            settingsStore.save(newValue)
            dress(newValue)
        }
    }
    var verbose: Bool {
        get { chosenVerbose }
        set {
            chosenVerbose = newValue
            settingsStore.save(verbose: newValue)
        }
    }
    var slot: Int {
        get { chosenSlot }
        set {
            chosenSlot = newValue
            settingsStore.save(slot: newValue)
            refreshReadPlan()
        }
    }
    var alsoMidi: Bool {
        get { chosenAlsoMidi }
        set {
            chosenAlsoMidi = newValue
            settingsStore.save(alsoMidi: newValue)
            refreshReadPlan()
        }
    }
    var readName: String = "" { didSet { refreshReadPlan() } }
    private(set) var readPreview: ReadPreview?
    private(set) var recentFiles: [URL] = []
    private(set) var folders: Folders { didSet { refreshReadPlan() } }
    private(set) var deviceReadPlan: DeviceRead.Plan

    private var chosenAppearance: Appearance
    private var chosenVerbose: Bool
    private var chosenSlot: Int
    private var chosenAlsoMidi: Bool
    private var dryRun = false
    private var slots: [Job.Kind: Settings]
    private var lastKind: Job.Kind = .toProject

    private let store: FolderStore
    private let settingsStore: SettingsStore
    private let destination: (Job, Folders) -> Destination
    private let reveal: ([URL]) -> Void
    private let chooseFolder: @MainActor (URL?) -> URL?
    private let chooseFile: @MainActor () -> URL?
    private let recents: RecentFiles
    private let pull: @Sendable (PullRunner.Options) -> RunResult
    private let dress: @MainActor (Appearance) -> Void

    init(
        store: FolderStore = FolderStore(),
        settingsStore: SettingsStore = SettingsStore(),
        destination: @escaping (Job, Folders) -> Destination = AppModel.destination(for:folders:),
        reveal: @escaping ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) },
        chooseFolder: @escaping @MainActor (URL?) -> URL? = AppModel.chooseFolder(startingAt:),
        chooseFile: @escaping @MainActor () -> URL? = AppModel.chooseFile,
        recents: RecentFiles = .documentController,
        pull: @escaping @Sendable (PullRunner.Options) -> RunResult = { PullRunner.run($0) },
        dress: @escaping @MainActor (Appearance) -> Void = { NSApp?.appearance = $0.nsAppearance }
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.destination = destination
        self.reveal = reveal
        self.chooseFolder = chooseFolder
        self.chooseFile = chooseFile
        self.recents = recents
        self.pull = pull
        self.dress = dress
        let loaded = store.load()
        let slot = settingsStore.loadSlot()
        let alsoMidi = settingsStore.loadAlsoMidi()
        self.folders = loaded
        self.chosenAppearance = settingsStore.loadAppearance()
        self.chosenVerbose = settingsStore.loadVerbose()
        self.chosenSlot = slot
        self.chosenAlsoMidi = alsoMidi
        self.slots = Dictionary(
            uniqueKeysWithValues: Job.Kind.allCases.map { ($0, settingsStore.load($0)) })
        self.deviceReadPlan = AppModel.readPlan(
            slot: slot, named: "", folders: loaded, alsoMidi: alsoMidi)
        self.recentFiles = recents.urls()
        dress(chosenAppearance)
    }

    var kind: Job.Kind { staged?.job.kind ?? lastKind }

    var settings: Settings {
        get {
            var out = slots[kind] ?? Settings()
            out.dryRun = dryRun
            out.verbose = chosenVerbose
            return out
        }
        set {
            dryRun = newValue.dryRun
            verbose = newValue.verbose
            var kept = newValue
            kept.dryRun = false
            kept.verbose = false
            slots[kind] = kept
            settingsStore.save(kept, for: kind)
        }
    }

    nonisolated static func destination(for job: Job, folders: Folders) -> Destination {
        switch job {
        case .toProject: return Destinations.forProjects(chosen: folders.project)
        case .toMIDI: return Destinations.forMIDI(source: job.source, chosen: folders.midi)
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

    @MainActor
    private static func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Conversion.openableTypes
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        return panel.runModal() == .OK ? panel.url : nil
    }

    var staged: Staged? {
        guard case .staged(let staged) = phase else { return nil }
        return staged
    }

    var canAccept: Bool {
        switch phase {
        case .working, .reading: return false
        case .idle, .staged, .done: return true
        }
    }

    func open() {
        guard canAccept, let picked = chooseFile() else { return }
        accept(picked)
    }

    func clearRecentFiles() {
        recents.clear()
        recentFiles = recents.urls()
    }

    func accept(_ url: URL) {
        guard canAccept else { return }
        guard let job = Conversion.job(for: url) else {
            phase = .done(
                Outcome(
                    written: [],
                    headline: "\(url.lastPathComponent) is not a MIDI file or a KeyStep Pro "
                        + "project.", report: Report(), note: nil))
            return
        }
        recents.note(url)
        recentFiles = recents.urls()
        switch phase {
        case .staged, .done: dryRun = false
        case .idle, .working, .reading: break
        }
        name = Naming.stem(of: url)
        lastKind = job.kind
        readPreview = nil
        phase = .staged(Staged(job: job))
    }

    func summarise() async {
        guard let staged, staged.summary == .loading else { return }
        let state = await Conversion.summarise(staged.job)

        guard case .staged(var current) = phase, current.id == staged.id else { return }
        current.summary = state
        switch state {
        case .project(let summary): current.selection = GridSelection(summary)
        case .song(let summary): current.sourceSelection = SourceTrackSelection(summary)
        case .loading, .failed: break
        }
        phase = .staged(current)
    }

    struct PreviewKey: Equatable {
        let drop: UUID
        let settings: Settings
    }

    var segmentationKey: PreviewKey? {
        guard let staged, case .toProject = staged.job else { return nil }
        return PreviewKey(
            drop: staged.id,
            settings: settings.selecting(staged.sourceSelection))
    }

    func segment() async {
        guard let staged, let key = segmentationKey else { return }
        let answer = await Conversion.segment(staged.job, settings: key.settings)

        guard segmentationKey == key, case .staged(var current) = phase else { return }
        current.segmentation = answer
        phase = .staged(current)
    }

    var arrangementKey: PreviewKey? {
        guard let staged, case .toMIDI = staged.job else { return nil }
        return PreviewKey(drop: staged.id, settings: settings.selecting(staged.selection))
    }

    func arrange() async {
        guard let staged, let key = arrangementKey else { return }
        let answer = await Conversion.arrange(staged.job, settings: key.settings)

        guard arrangementKey == key, case .staged(var current) = phase else { return }
        current.arrangement = answer
        phase = .staged(current)
    }

    func conversionSettings(_ staged: Staged) -> Settings {
        settings.selecting(staged.selection).selecting(staged.sourceSelection)
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

    var drumSense: DrumSense { settings.drumSense(named: staged?.sourceSelection.drumTrack) }

    var drumChoices: [DrumChoice] {
        let named = staged?.sourceSelection.drumTrack.map(DrumChoice.source)
        return [.automatic] + (named.map { [$0] } ?? []) + [.none]
    }

    var drumChoice: DrumChoice {
        get {
            guard let named = staged?.sourceSelection.drumTrack else {
                return settings.drums == .none ? .none : .automatic
            }
            return .source(named)
        }
        set {
            switch newValue {
            case .source: break
            case .automatic, .none:
                settings.drums = newValue == .none ? .none : .automatic
                mutate { $0.sourceSelection.clearDrums() }
            }
        }
    }

    private func mutate(_ change: (inout Staged) -> Void) {
        guard case .staged(var staged) = phase else { return }
        change(&staged)
        phase = .staged(staged)
        discardPreview()
    }

    var blockReason: String? { staged?.blockReason(settings) }

    func discardPreview() {
        guard case .staged(var staged) = phase, staged.preview != nil else { return }
        staged.preview = nil
        phase = .staged(staged)
    }

    func convert() async {
        guard let staged, blockReason == nil else { return }
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
        phase = .done(outcome)
    }

    private var resolvedReadPlan: DeviceRead.Plan {
        AppModel.readPlan(slot: slot, named: readName, folders: folders, alsoMidi: alsoMidi)
    }

    private static func readPlan(
        slot: Int, named: String, folders: Folders, alsoMidi: Bool
    ) -> DeviceRead.Plan {
        DeviceRead.plan(
            slot: slot, named: named, into: Destinations.forProjects(chosen: folders.project),
            alsoMidi: alsoMidi)
    }

    private func refreshReadPlan() { deviceReadPlan = resolvedReadPlan }

    var deviceMIDINote: String? {
        guard alsoMidi, folders.midi != nil else { return nil }
        return "The MIDI file is written beside the project, not in the MIDI files folder."
    }

    func read() async {
        guard case .idle = phase else { return }
        let plan = resolvedReadPlan
        phase = .reading(plan.slot)

        let outcome = await DeviceRead.run(plan, verbose: settings.verbose, pull: pull)

        readPreview = outcome.failed ? nil : ReadPreview(project: plan.target)
        phase = .done(outcome)
    }

    func revealWritten() {
        guard case .done(let outcome) = phase, !outcome.failed else { return }
        reveal(outcome.written)
    }

    func previewRead() async {
        guard let pending = readPreview, pending.summary == .loading else { return }
        let job = Job.toMIDI(pending.project)

        async let summarised = Conversion.summarise(job)
        async let arranged = Conversion.arrange(job, settings: Settings())

        let summary = await summarised
        guard readPreview?.project == pending.project else { return }
        readPreview?.summary = summary

        let arrangement = await arranged
        guard readPreview?.project == pending.project else { return }
        readPreview?.arrangement = arrangement
    }

    func cancel() { reset() }

    func reset() {
        phase = .idle
        dryRun = false
        name = ""
        readName = ""
        readPreview = nil
    }
}
