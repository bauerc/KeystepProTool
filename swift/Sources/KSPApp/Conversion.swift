import Foundation
import KSPKit
import KSPRun

/// Which direction a dropped file goes.
enum Job: Sendable, Hashable {
    /// A `.mid` in, a `.KeyStepPro` into MCC's Templates folder.
    case toProject(URL)
    /// A `.KeyStepPro` in, a `.mid` beside it -- the direction MCC does not have at all.
    case toMIDI(URL)

    var source: URL {
        switch self {
        case .toProject(let url), .toMIDI(let url): return url
        }
    }
}

/// What the window shows after a run.
///
/// The findings, the destination and a failure's message come from ``RunResult``'s structured half.
/// The one thing read out of the terminal text is the success summary, and only to drop its first
/// line -- see ``summary(_:)``.
struct Outcome: Sendable, Equatable {
    /// What the run wrote -- or, under a dry run, what it would have written.
    var written: URL?
    var headline: String
    var note: String?
    /// True when nothing was written because the user asked for a report instead.
    let dryRun: Bool

    /// The findings rendered both ways, once. SwiftUI re-evaluates a body far more often than a
    /// conversion happens, and `Report.grouped()` allocates on every call.
    let collapsed: [String]
    let all: [String]

    init(written: URL?, headline: String, report: Report, note: String?, dryRun: Bool = false) {
        self.written = written
        self.headline = headline
        self.note = note
        self.dryRun = dryRun
        // `Report.note(verbose:)` is deliberately not used: it ends in "--verbose for detail",
        // which names a flag rather than the sidebar's toggle.
        self.collapsed = report.render(verbose: false)
        self.all = report.render(verbose: true)
    }

    var failed: Bool { written == nil }

    /// Whether there is a file on disk to reveal. A dry run names one without creating it, so the
    /// two are not the same question.
    var wroteFile: Bool { !failed && !dryRun }

    func findings(verbose: Bool) -> [String] { verbose ? all : collapsed }
}

enum Conversion {
    /// A conversion decided but not yet run: what was dropped, where its result would go, and
    /// anything the user should know about that placement before pressing Convert.
    struct Plan: Sendable, Hashable {
        let job: Job
        let target: URL
        /// A fallback directory, a name already taken, or both. `nil` when the obvious thing
        /// happened.
        let note: String?

        var source: URL { job.source }
    }

    /// The two extensions each direction answers to. A drop of anything else is refused before a
    /// runner is ever called, so an unreadable file is a message rather than an exit code.
    static func job(for url: URL) -> Job? {
        switch url.pathExtension.lowercased() {
        case "mid", "midi": return .toProject(url)
        case "keysteppro": return .toMIDI(url)
        default: return nil
        }
    }

    /// Where a drop would go, decided before anything runs.
    ///
    /// Separated from ``run(_:settings:)`` so the staged view can show the destination and its notes
    /// while the user is still deciding, and so pressing Convert re-asks the same question against
    /// the filesystem as it is at that moment.
    static func plan(_ job: Job, named stem: String, into destination: Destination) -> Plan {
        let base = Naming.sanitised(stem)
        let target = Naming.vacant(
            in: destination.directory, stem: base, extension: job.extensionOfResult)
        // Both notes can apply at once -- a fallback directory that already holds that name -- so
        // they are collected rather than chosen between.
        let clashed = target.deletingPathExtension().lastPathComponent != base
        let note = [destination.note, clashed ? collisionNote(target) : nil]
            .compactMap { $0 }.joined(separator: " ")
        return Plan(job: job, target: target, note: note.isEmpty ? nil : note)
    }

    /// Run one conversion off the main actor.
    ///
    /// A 3.5 MB parse, a placement pass and a 3.5 MB write take long enough to freeze a window.
    /// The runners are synchronous and their `Options`/`RunResult` are `Sendable`, so the whole
    /// job crosses to a detached task and only the `Outcome` comes back.
    static func run(_ plan: Plan, settings: Settings) async -> Outcome {
        let target = plan.target
        let result = await Task.detached(priority: .userInitiated) {
            switch plan.job {
            case .toProject(let source):
                return ConvertRunner.run(settings.convertOptions(source: source, output: target))
            case .toMIDI(let source):
                return ExportRunner.run(settings.exportOptions(source: source, output: target))
            }
        }.value

        return outcome(from: result, note: plan.note, dryRun: settings.dryRun)
    }

    private static func outcome(from result: RunResult, note: String?, dryRun: Bool) -> Outcome {
        guard result.code == 0, let written = result.destinations.first else {
            return Outcome(
                written: nil, headline: result.message ?? "Conversion failed.",
                report: result.diagnostics, note: nil, dryRun: dryRun)
        }
        return Outcome(
            written: written, headline: summary(result), report: result.diagnostics, note: note,
            dryRun: dryRun)
    }

    /// The runner's own summary, minus its first line -- which names the path this window is
    /// already showing.
    private static func summary(_ result: RunResult) -> String {
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        let detail = lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return detail.isEmpty ? "Converted." : detail.joined(separator: "\n")
    }

    /// Worded to read the same before the write and after it, because the staged view and the
    /// result view both show it.
    private static func collisionNote(_ target: URL) -> String {
        "That name is taken, so this one is \(target.lastPathComponent)."
    }
}

extension Job {
    /// What the conversion produces, which is the opposite of what was dropped.
    var extensionOfResult: String {
        switch self {
        case .toProject: return "KeyStepPro"
        case .toMIDI: return "mid"
        }
    }

    /// Which way this is about to go, for the staged view to state before anything is written.
    var direction: String {
        switch self {
        case .toProject: return "MIDI file → KeyStep Pro project"
        case .toMIDI: return "KeyStep Pro project → MIDI file"
        }
    }
}
