import Foundation
import KSPKit
import KSPRun

/// Which direction a dropped file goes.
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
    /// What the run wrote, or would have written under a dry run. Empty is the failure.
    var written: [URL]
    var headline: String
    var note: String?
    /// The folder a split run filled; `nil` when the run wrote a single named file.
    let folder: URL?
    let dryRun: Bool

    /// Rendered once: SwiftUI re-evaluates a body far more often than a conversion happens.
    let collapsed: [String]
    let all: [String]

    init(
        written: [URL], headline: String, report: Report, note: String?, folder: URL? = nil,
        dryRun: Bool = false
    ) {
        self.written = written
        self.headline = headline
        self.note = note
        self.folder = folder
        self.dryRun = dryRun
        // Not `Report.note(verbose:)`: its text names a CLI flag, not the sidebar's toggle.
        self.collapsed = report.render(verbose: false)
        self.all = report.render(verbose: true)
    }

    var failed: Bool { written.isEmpty }

    var resultLine: String {
        if failed { return "Nothing was written" }
        return written.count == 1 ? written[0].lastPathComponent : "\(written.count) files written"
    }

    var previewLine: String {
        if failed { return "Nothing would be written" }
        return written.count == 1
            ? "Would write \(written[0].lastPathComponent)" : "Would write \(written.count) files"
    }

    var wroteFile: Bool { !failed && !dryRun }

    func findings(verbose: Bool) -> [String] { verbose ? all : collapsed }
}

/// What a staged file turned out to hold. Both drop kinds are read; only the shape differs.
enum SummaryState: Equatable {
    case loading
    case project(ProjectSummary)
    case song(SongSummary)
    case failed(String)
}

/// What the import would lay down, and what the planner already found wrong with it.
struct StagedPlan: Equatable {
    let summary: SegmentationSummary
    /// Rendered once, for the reason ``Outcome`` renders its own once.
    let collapsed: [String]
    let all: [String]

    init(summary: SegmentationSummary, diagnostics: Report) {
        self.summary = summary
        self.collapsed = diagnostics.render(verbose: false)
        self.all = diagnostics.render(verbose: true)
    }

    func findings(verbose: Bool) -> [String] { verbose ? all : collapsed }
}

/// What the import would lay down. Import-only, so a staged project leaves it at ``loading``.
enum SegmentationState: Equatable {
    case loading
    case ready(StagedPlan)
    case failed(String)
}

enum Conversion {
    struct Plan: Sendable, Hashable {
        let job: Job
        /// Where the result lands: the file it writes, or the folder it fills.
        let target: URL
        let note: String?
        let intoFolder: Bool

        var source: URL { job.source }
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
        return outcome(
            from: result, note: note.isEmpty ? nil : note, excluded: excluded,
            dryRun: settings.dryRun, folder: plan.intoFolder ? target : nil)
    }

    /// Detached for the reason a conversion is: the parse is the file's whole size and the window
    /// must keep drawing. The job, not the path, says which runner reads it.
    static func summarise(_ job: Job) async -> SummaryState {
        switch job {
        case .toMIDI(let source):
            let result = await Task.detached(priority: .userInitiated) {
                SummaryRunner.run(SummaryRunner.Options(path: source))
            }.value
            if let summary = result.summary { return .project(summary) }
            return .failed(result.message ?? "That project could not be read.")
        case .toProject(let source):
            let result = await Task.detached(priority: .userInitiated) {
                SummaryRunner.song(SummaryRunner.Options(path: source))
            }.value
            if let summary = result.summary { return .song(summary) }
            return .failed(result.message ?? "That MIDI file could not be read.")
        }
    }

    /// Detached for the reason ``summarise`` is. It plans and writes nothing, so no destination is
    /// resolved and none is needed.
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

    static func outcome(
        from result: RunResult, note: String?, excluded: String?, dryRun: Bool,
        folder: URL? = nil
    ) -> Outcome {
        guard result.code == 0, !result.destinations.isEmpty else {
            // Nothing was written, so only the exclusion still explains anything.
            return Outcome(
                written: [], headline: result.message ?? "Conversion failed.",
                report: result.diagnostics, note: excluded, dryRun: dryRun)
        }
        return Outcome(
            written: result.destinations, headline: summary(result), report: result.diagnostics,
            note: note, folder: folder, dryRun: dryRun)
    }

    /// The runner's own summary, minus its first line -- the path this window already shows.
    private static func summary(_ result: RunResult) -> String {
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        let detail = lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return detail.isEmpty ? "Converted." : detail.joined(separator: "\n")
    }

    private static func collisionNote(_ target: URL) -> String {
        "That name is taken, so this one is \(target.lastPathComponent)."
    }
}

extension Job {
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

    /// A project was dropped, which is the ``toMIDI`` direction.
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
