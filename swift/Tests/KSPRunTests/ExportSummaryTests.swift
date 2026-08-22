import Foundation
import Testing

@testable import KSPRun

@Suite struct ExportSummaryTests {
    static func run(repeat count: Int) -> RunResult {
        ExportRunner.run(
            ExportRunner.Options(
                path: RepoData.projectFiles.appending(path: "project_5.KeyStepPro"),
                repeatCount: count, dryRun: true, configPath: noPersonalConfig))
    }

    @Test func theCountIsReportedOnlyWhenItIsNotOne() {
        #expect(!Self.run(repeat: 1).stdout.contains("repeated"))
        #expect(Self.run(repeat: 2).stdout.contains("\n  repeated 2 times end to end"))
    }

    @Test func theNoteCountCoversEveryRound() {
        #expect(Self.run(repeat: 1).stdout.contains("32 note(s)"))
        #expect(Self.run(repeat: 2).stdout.contains("64 note(s)"))
    }
}
