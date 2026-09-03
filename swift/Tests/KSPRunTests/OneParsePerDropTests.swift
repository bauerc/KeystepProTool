import Foundation
import KSPKit
import Testing

@testable import KSPRun

/// One drop wakes four readers. Deleting the file after the first proves the rest never re-read
/// it, which counting parses cannot: the cache's counters are global and other suites share them.
@Suite struct OneParsePerDropTests {
    static func options(_ path: URL, dryRun: Bool = false) -> ExportRunner.Options {
        ExportRunner.Options(path: path, dryRun: dryRun, configPath: noPersonalConfig)
    }

    static func copyOfSample() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ksp-\(UUID().uuidString).KeyStepPro")
        try FileManager.default.copyItem(
            at: RepoData.projectFiles.appending(path: "project_9.KeyStepPro"), to: url)
        return url
    }

    @Test func theReadersAfterTheFirstNeverTouchTheFileAgain() throws {
        let path = try Self.copyOfSample()
        defer { try? FileManager.default.removeItem(at: path) }

        let summary = SummaryRunner.run(SummaryRunner.Options(path: path))
        #expect(summary.summary != nil)

        try FileManager.default.removeItem(at: path)

        let arrangement = ArrangementRunner.run(Self.options(path))
        #expect(arrangement.message == nil)
        #expect(arrangement.summary != nil)

        let export = ExportRunner.run(Self.options(path, dryRun: true))
        #expect(export.code == 0)
    }

    @Test func aprojectNeverReadIsStillAmissingFile() throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "ksp-\(UUID().uuidString).KeyStepPro")
        #expect(SummaryRunner.run(SummaryRunner.Options(path: path)).summary == nil)
    }
}
