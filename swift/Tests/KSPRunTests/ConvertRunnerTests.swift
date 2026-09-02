import Foundation
import KSPMIDI
import Testing

@testable import KSPRun

/// `--dry-run` throughout: these run against the real fixtures, so nothing may write beside them.
private func options(
    _ name: String, drumTrack: Int? = nil, noDrums: Bool = false,
    drumChannel: Int = MIDIImport.drumChannel, midiTrack: Int? = nil, quiet: Bool = false
) -> ConvertRunner.Options {
    ConvertRunner.Options(
        paths: [RepoData.projectFiles.appending(path: name)],
        output: FileManager.default.temporaryDirectory
            .appending(path: "ksp174-\(UUID().uuidString).KeyStepPro"),
        drumTrack: drumTrack, noDrums: noDrums, drumChannel: drumChannel, midiTrack: midiTrack,
        dryRun: true, quiet: quiet, configPath: noPersonalConfig)
}

@Suite struct ConvertRunnerTests {
    /// Channel 1 is what makes m6-test-file's kit findable, so a real detection is suppressed.
    @Test func nodrumsTakesNothingAsDrums() {
        let result = ConvertRunner.run(options("m6-test-file.mid", noDrums: true, drumChannel: 0))

        #expect(result.code == 0)
        #expect(result.stdout.hasSuffix("\n  no source track was taken as drums"))
        #expect(!result.stdout.contains("[drum]"))
        #expect(!result.stderr.contains("fitted to the source"))
    }

    @Test func withoutNodrumsTheDrumChannelIsStillSearched() {
        let result = ConvertRunner.run(options("m6-test-file.mid", drumChannel: 0))

        #expect(result.code == 0)
        #expect(result.stdout.contains("[drum]"))
        #expect(!result.stdout.contains("no source track was taken as drums"))
    }

    /// The single-target shape returned before the tail line existed.
    @Test func nodrumsReachesTheSingleTargetSummary() {
        let result = ConvertRunner.run(
            options("test_file_simple.mid", noDrums: true, midiTrack: 1))

        #expect(result.code == 0)
        #expect(result.stdout.contains("note(s) onto track 1"))
        #expect(result.stdout.hasSuffix("\n  no source track was taken as drums"))
    }

    @Test func nodrumsWithADrumTrackIsTwo() {
        let result = ConvertRunner.run(options("m6-test-file.mid", drumTrack: 1, noDrums: true))

        #expect(result.code == 2)
        #expect(
            result.message
                == "--drum-track and --no-drums contradict each other; --drum-track names a "
                + "source track to write as drums, and --no-drums takes none")
    }

    @Test func nodrumsSaysNothingUnderQuiet() {
        let result = ConvertRunner.run(options("m6-test-file.mid", noDrums: true, quiet: true))

        #expect(result.code == 0)
        #expect(result.stdout.isEmpty)
    }
}
