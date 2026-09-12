import Foundation
import KSPKit
import KSPRun
import UniformTypeIdentifiers

enum Job: Sendable, Hashable {
    case toProject(URL)
    case toMIDI(URL)

    var source: URL {
        switch self {
        case .toProject(let url), .toMIDI(let url): return url
        }
    }
}

struct Outcome: Sendable, Equatable {
    enum Source: Sendable {
        case conversion
        case deviceRead
    }

    var written: [URL]
    var headline: String
    var note: String?
    let folder: URL?
    let dryRun: Bool
    let source: Source
    var document = ""
    var direction = ""

    let collapsedRows: [Finding]
    let allRows: [Finding]

    init(
        written: [URL], headline: String, report: Report, note: String?, folder: URL? = nil,
        dryRun: Bool = false, source: Source = .conversion
    ) {
        self.written = written
        self.headline = headline
        self.note = note
        self.folder = folder
        self.dryRun = dryRun
        self.source = source
        self.collapsedRows = report.rows(verbose: false)
        self.allRows = report.rows(verbose: true)
    }

    var collapsed: [String] { collapsedRows.map(\.text) }
    var all: [String] { allRows.map(\.text) }

    var failed: Bool { written.isEmpty }

    var directory: URL? { folder ?? written.first?.deletingLastPathComponent() }

    var resultLine: String {
        if failed { return source == .deviceRead ? "Nothing was read" : "Nothing was written" }
        return written.count == 1 ? written[0].lastPathComponent : "\(written.count) files written"
    }

    var againLabel: String {
        source == .deviceRead ? "Read another" : "Convert another"
    }

    var previewLine: String {
        if failed { return "Nothing would be written" }
        return written.count == 1
            ? "Would write \(written[0].lastPathComponent)" : "Would write \(written.count) files"
    }

    var wroteFile: Bool { !failed && !dryRun }

    func rows(verbose: Bool) -> [Finding] { verbose ? allRows : collapsedRows }

    func findings(verbose: Bool) -> [String] { rows(verbose: verbose).map(\.text) }
}

enum SummaryState: Equatable {
    case loading
    case project(ProjectSummary)
    case song(SongSummary)
    case failed(ReadFailure)
}

struct StagedPlan: Equatable {
    let summary: SegmentationSummary
    let collapsedRows: [Finding]
    let allRows: [Finding]

    init(summary: SegmentationSummary, diagnostics: Report) {
        self.summary = summary
        self.collapsedRows = diagnostics.rows(verbose: false)
        self.allRows = diagnostics.rows(verbose: true)
    }

    var collapsed: [String] { collapsedRows.map(\.text) }
    var all: [String] { allRows.map(\.text) }

    func rows(verbose: Bool) -> [Finding] { verbose ? allRows : collapsedRows }

    func findings(verbose: Bool) -> [String] { rows(verbose: verbose).map(\.text) }
}

enum ArrangementState: Equatable {
    case loading
    case ready(ArrangementSummary)
    case failed(String)
}

enum SegmentationState: Equatable {
    case loading
    case ready(StagedPlan)
    case failed(String)
}

enum Conversion {
    struct Plan: Sendable, Hashable {
        let job: Job
        let target: URL
        let note: String?
        let intoFolder: Bool

        var source: URL { job.source }
    }

    static let openableExtensions = ["mid", "midi", "KeyStepPro"]

    static var openableTypes: [UTType] {
        openableExtensions.compactMap { UTType(filenameExtension: $0) }
            .reduce(into: [UTType]()) { unique, type in
                if !unique.contains(type) { unique.append(type) }
            }
    }

    static func job(for url: URL) -> Job? {
        switch url.pathExtension.lowercased() {
        case "mid", "midi": return .toProject(url)
        case "keysteppro": return .toMIDI(url)
        default: return nil
        }
    }

    static func plan(
        _ job: Job, named stem: String, into destination: Destination, splitting: Bool = false
    ) -> Plan {
        let base = Naming.sanitised(stem)
        let intoFolder = splitting && job.writesMIDI
        let target =
            intoFolder
            ? Naming.vacantFolder(in: destination.directory, stem: base)
            : Naming.vacant(
                in: destination.directory, stem: base, extension: job.extensionOfResult)
        let claimed =
            intoFolder
            ? target.lastPathComponent
            : target.deletingPathExtension()
                .lastPathComponent
        let note = [destination.note, claimed != base ? collisionNote(target) : nil]
            .compactMap { $0 }.joined(separator: " ")
        return Plan(
            job: job, target: target, note: note.isEmpty ? nil : note, intoFolder: intoFolder)
    }

    static func run(_ plan: Plan, settings: Settings, excluded: String? = nil) async -> Outcome {
        let target = plan.target
        let result = await Task.detached(priority: .userInitiated) {
            switch plan.job {
            case .toProject(let source):
                return ConvertRunner.run(settings.convertOptions(source: source, output: target))
            case .toMIDI(let source):
                return ExportRunner.run(settings.exportOptions(source: source, output: target))
            }
        }.value

        let note = [plan.note, excluded].compactMap { $0 }.joined(separator: " ")
        var made = outcome(
            from: result, note: note.isEmpty ? nil : note, excluded: excluded,
            dryRun: settings.dryRun, folder: plan.intoFolder ? target : nil)
        made.document = plan.source.lastPathComponent
        made.direction = plan.job.direction
        return made
    }

    static func summarise(_ job: Job) async -> SummaryState {
        switch job {
        case .toMIDI(let source):
            let result = await Task.detached(priority: .userInitiated) {
                SummaryRunner.run(SummaryRunner.Options(path: source))
            }.value
            switch result {
            case .read(let summary): return .project(summary)
            case .failed(let failure): return .failed(ReadFailure(failure, kind: job.kind))
            }
        case .toProject(let source):
            let result = await Task.detached(priority: .userInitiated) {
                SummaryRunner.song(SummaryRunner.Options(path: source))
            }.value
            switch result {
            case .read(let summary): return .song(summary)
            case .failed(let failure): return .failed(ReadFailure(failure, kind: job.kind))
            }
        }
    }

    static func segment(_ job: Job, settings: Settings) async -> SegmentationState {
        guard case .toProject(let source) = job else {
            return .loading
        }
        let outcome = await Task.detached(priority: .userInitiated) {
            SegmentationRunner.run(settings.convertOptions(source: source, output: nil))
        }.value
        guard let summary = outcome.summary else {
            return .failed(outcome.message ?? "That MIDI file could not be read.")
        }
        return .ready(StagedPlan(summary: summary, diagnostics: outcome.diagnostics))
    }

    static func arrange(_ job: Job, settings: Settings) async -> ArrangementState {
        guard case .toMIDI(let source) = job else {
            return .loading
        }
        let outcome = await Task.detached(priority: .userInitiated) {
            ArrangementRunner.run(settings.exportOptions(source: source, output: nil))
        }.value
        guard let summary = outcome.summary else {
            return .failed(outcome.message ?? "That project could not be laid out.")
        }
        return .ready(summary)
    }

    static func outcome(
        from result: RunResult, note: String?, excluded: String?, dryRun: Bool,
        folder: URL? = nil
    ) -> Outcome {
        guard result.code == 0, !result.destinations.isEmpty else {
            return Outcome(
                written: [], headline: result.message ?? "Conversion failed.",
                report: result.diagnostics, note: excluded, dryRun: dryRun)
        }
        return Outcome(
            written: result.destinations, headline: summary(result), report: result.diagnostics,
            note: note, folder: folder, dryRun: dryRun)
    }

    private static func summary(_ result: RunResult) -> String {
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        let detail = lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return detail.isEmpty ? "Converted." : detail.joined(separator: "\n")
    }

    static func collisionNote(_ target: URL) -> String {
        "That name is taken, so this one is \(target.lastPathComponent)."
    }
}

extension Job {
    enum Kind: String, CaseIterable, Sendable {
        case toProject
        case toMIDI
    }

    var kind: Kind {
        switch self {
        case .toProject: return .toProject
        case .toMIDI: return .toMIDI
        }
    }

    var writesMIDI: Bool {
        if case .toMIDI = self { return true }
        return false
    }

    var extensionOfResult: String {
        switch self {
        case .toProject: return "KeyStepPro"
        case .toMIDI: return "mid"
        }
    }

    var folderKind: FolderKind {
        switch self {
        case .toProject: return .project
        case .toMIDI: return .midi
        }
    }

    var isProject: Bool {
        if case .toMIDI = self { return true }
        return false
    }

    var direction: String {
        switch self {
        case .toProject: return "MIDI file → KeyStep Pro project"
        case .toMIDI: return "KeyStep Pro project → MIDI file"
        }
    }
}
