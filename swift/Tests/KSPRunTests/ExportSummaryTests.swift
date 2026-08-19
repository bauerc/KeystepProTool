import Foundation
import Testing

@testable import KSPRun

/// What `ksp-swift-cli export` prints, which `ksp2midi` prints byte for byte.
@Suite struct ExportSummaryTests {
    static func run(repeat count: Int) -> RunResult {
        ExportRunner.run(
            ExportRunner.Options(
                path: RepoData.projectFiles.appending(path: "project_5.KeyStepPro"),
                repeatCount: count, dryRun: true, configPath: noPersonalConfig))
    }

    /// A count of one is what every export has always done, so it goes unsaid.
    @Test func theCountIsReportedOnlyWhenItIsNotOne() {
        #expect(!Self.run(repeat: 1).stdout.contains("repeated"))
        #expect(Self.run(repeat: 2).stdout.contains("\n  repeated 2 times end to end"))
    }

    @Test func theNoteCountCoversEveryRound() {
        #expect(Self.run(repeat: 1).stdout.contains("32 note(s)"))
        #expect(Self.run(repeat: 2).stdout.contains("64 note(s)"))
    }
}
