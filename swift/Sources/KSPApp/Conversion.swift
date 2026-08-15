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
/// Built from ``RunResult``'s structured half -- `diagnostics` and `destinations` -- never by
/// re-parsing the text meant for a terminal. The `Report` is carried whole rather than pre-rendered
/// so the detail toggle can re-render it without converting again.
struct Outcome: Sendable {
    var written: URL?
    var headline: String
    var report: Report
    var note: String?

    var failed: Bool { written == nil }

    /// The findings, collapsed by default. `Report.note(verbose:)` is deliberately not used: it
    /// ends in "--verbose for detail", which names a flag this app does not have.
    func findings(verbose: Bool) -> [String] { report.render(verbose: verbose) }

    /// True only when collapsing is actually hiding something, so the toggle appears when it has
    /// work to do and not otherwise.
    var hasDetail: Bool { report.count > report.grouped().count }
}

enum Conversion {
    /// The two extensions each direction answers to. A drop of anything else is refused before a
    /// runner is ever called, so an unreadable file is a message rather than an exit code.
    static func job(for url: URL) -> Job? {
        switch url.pathExtension.lowercased() {
        case "mid", "midi": return .toProject(url)
        case "keysteppro": return .toMIDI(url)
        default: return nil
        }
    }

    /// Run one conversion off the main actor.
    ///
    /// A 3.5 MB parse, a placement pass and a 3.5 MB write take long enough to freeze a window.
    /// The runners are synchronous and their `Options`/`RunResult` are `Sendable`, so the whole
    /// job crosses to a detached task and only the `Outcome` comes back.
    static func run(_ job: Job, named stem: String, into destination: Destination) async -> Outcome
    {
        let target = Naming.vacant(
            in: destination.directory, stem: stem, extension: job.extensionOfResult)
        // Both notes can apply at once -- a fallback directory that already holds that name -- so
        // they are collected rather than chosen between.
        let clashed = target.deletingPathExtension().lastPathComponent != Naming.sanitised(stem)
        let note = [destination.note, clashed ? collisionNote(target) : nil]
            .compactMap { $0 }.joined(separator: " ")

        let result = await Task.detached(priority: .userInitiated) {
            switch job {
            case .toProject(let source):
                // `force` stays false: `vacant` already guarantees nothing is there, so the
                // runner's own guard is left in place as a backstop rather than waived.
                return ConvertRunner.run(
                    ConvertRunner.Options(
                        path: source, output: target, configPath: drumMapConfigPath))
            case .toMIDI(let source):
                return ExportRunner.run(
                    ExportRunner.Options(
                        path: source, output: target, configPath: drumMapConfigPath))
            }
        }.value

        return outcome(from: result, note: note.isEmpty ? nil : note)
    }

    private static func outcome(from result: RunResult, note: String?) -> Outcome {
        guard result.code == 0, let written = result.destinations.first else {
            return Outcome(
                written: nil, headline: failureMessage(result), report: result.diagnostics,
                note: nil)
        }
        return Outcome(
            written: written, headline: summary(result), report: result.diagnostics, note: note)
    }

    /// The runner spells a failure `<prog>: <message>` for a terminal. The window already knows
    /// which command it ran, so the prefix is dropped and the sentence kept.
    private static func failureMessage(_ result: RunResult) -> String {
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = text.split(separator: "\n").first else { return "Conversion failed." }
        guard let colon = line.range(of: ": ") else { return String(line) }
        return String(line[colon.upperBound...])
    }

    /// The runner's own summary, minus its first line -- which names the path this window is
    /// already showing.
    private static func summary(_ result: RunResult) -> String {
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        let detail = lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return detail.isEmpty ? "Converted." : detail.joined(separator: "\n")
    }

    private static func collisionNote(_ target: URL) -> String {
        "That name was taken, so this was written as \(target.lastPathComponent). "
            + "Rename it below if you would rather it were something else."
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
}
