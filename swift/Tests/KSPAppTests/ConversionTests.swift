import Foundation
import KSPKit
import KSPRun
import Testing

@testable import KSPApp

@Suite struct ConversionTests {
    @Test(arguments: ["song.mid", "song.MID", "song.midi", "song.MIDI"])
    func aMIDIFileConvertsTowardsAProject(name: String) {
        guard case .toProject = Conversion.job(for: URL(filePath: "/tmp/\(name)")) else {
            Issue.record("\(name) should have been a project conversion")
            return
        }
    }

    @Test(arguments: ["song.KeyStepPro", "song.keysteppro"])
    func aProjectConvertsTowardsMIDI(name: String) {
        guard case .toMIDI = Conversion.job(for: URL(filePath: "/tmp/\(name)")) else {
            Issue.record("\(name) should have been a MIDI export")
            return
        }
    }

    /// Refused before a runner is called, so a stray drop is a sentence in the window rather than
    /// an exit code the app has to translate.
    @Test(arguments: ["notes.txt", "song", "song.wav"])
    func anythingElseIsRefused(name: String) {
        #expect(Conversion.job(for: URL(filePath: "/tmp/\(name)")) == nil)
    }

    @Test func theResultExtensionIsTheOppositeOfWhatWasDropped() {
        #expect(Job.toProject(URL(filePath: "/a.mid")).extensionOfResult == "KeyStepPro")
        #expect(Job.toMIDI(URL(filePath: "/a.KeyStepPro")).extensionOfResult == "mid")
    }

    /// Planning is what the staged view shows before anything is written, so it has to name the
    /// destination the run will actually use.
    @Test func aPlanNamesWhereTheResultWillLand() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "m6-test-file.mid")

        let plan = Conversion.plan(
            .toProject(source), named: "fixture",
            into: Destination(directory: directory, note: nil))

        #expect(plan.target == directory.appending(path: "fixture.KeyStepPro"))
        // One target today, and the name field the staged view offers depends on it staying one.
        #expect(plan.targets == [directory.appending(path: "fixture.KeyStepPro")])
        #expect(plan.writesOneFile)
        #expect(plan.note == nil)
    }

    /// A second conversion of the same source under the same name must not destroy the first, and
    /// the staged view says so before the user commits to it.
    @Test func aPlanStepsAsideFromAnExistingFileAndSaysSo() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "m6-test-file.mid")
        try touch(directory, "fixture.KeyStepPro")

        let plan = Conversion.plan(
            .toProject(source), named: "fixture",
            into: Destination(directory: directory, note: nil))

        #expect(plan.target.lastPathComponent == "fixture 2.KeyStepPro")
        #expect(plan.note?.contains("fixture 2.KeyStepPro") == true)
    }

    /// Both notes can apply at once -- a fallback directory that already holds that name.
    @Test func aPlanCarriesTheDestinationNoteAndTheCollisionNoteTogether() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "m6-test-file.mid")
        try touch(directory, "fixture.KeyStepPro")

        let plan = Conversion.plan(
            .toProject(source), named: "fixture",
            into: Destination(directory: directory, note: "Templates was not writable."))

        #expect(plan.note?.contains("Templates was not writable.") == true)
        #expect(plan.note?.contains("fixture 2.KeyStepPro") == true)
    }

    /// The one end-to-end run, and the point of it is that the app reaches the *shipped* runner and
    /// finds the bundled 3.5 MB template through `Bundle.module` -- neither of which a unit test of
    /// the naming rules would catch.
    @Test func convertingAMIDIFileWritesAProjectWhereItWasAsked() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "m6-test-file.mid")
        let plan = Conversion.plan(
            .toProject(source), named: "fixture",
            into: Destination(directory: directory, note: nil))

        let outcome = await Conversion.run(plan, settings: Settings())

        let written = try #require(
            outcome.written.first, "conversion failed: \(outcome.headline)")
        #expect(!outcome.failed)
        #expect(outcome.wroteFile)
        #expect(written == directory.appending(path: "fixture.KeyStepPro"))
        #expect(FileManager.default.fileExists(atPath: written.path))
    }

    /// A dry run is a real feature against a 3.5 MB project, not scaffolding: it reports the file it
    /// would have written and leaves the disk untouched.
    @Test func adryRunReportsItsDestinationAndWritesNothing() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "m6-test-file.mid")
        let plan = Conversion.plan(
            .toProject(source), named: "fixture",
            into: Destination(directory: directory, note: nil))

        let outcome = await Conversion.run(plan, settings: Settings(dryRun: true))

        #expect(!outcome.failed)
        #expect(outcome.dryRun)
        // Nothing was written, so nothing may be revealed in Finder or renamed.
        #expect(!outcome.wroteFile)
        #expect(outcome.written == [plan.target])
        #expect(!FileManager.default.fileExists(atPath: plan.target.path))
    }

    /// The other direction takes the flag separately, so it is asserted separately.
    @Test func adryRunExportsNothingEither() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "project_5.KeyStepPro")
        let plan = Conversion.plan(
            .toMIDI(source), named: "fixture",
            into: Destination(directory: directory, note: nil))

        let outcome = await Conversion.run(plan, settings: Settings(dryRun: true))

        #expect(!outcome.failed)
        #expect(!outcome.wroteFile)
        #expect(!FileManager.default.fileExists(atPath: plan.target.path))
    }

    /// What the grid left out rides the same channel the placement notes do.
    @Test func whatWasLeftOutIsCarriedIntoTheResult() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "project_5.KeyStepPro")
        let plan = Conversion.plan(
            .toMIDI(source), named: "fixture",
            into: Destination(directory: directory, note: nil))

        let outcome = await Conversion.run(
            plan, settings: Settings(), excluded: "Excluded: Track 2")

        #expect(!outcome.failed)
        #expect(outcome.note == "Excluded: Track 2")
    }

    /// A name already taken and a track switched off can both apply.
    @Test func acollisionAndAnExclusionAreBothReported() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "project_5.KeyStepPro")
        try touch(directory, "fixture.mid")
        let plan = Conversion.plan(
            .toMIDI(source), named: "fixture",
            into: Destination(directory: directory, note: nil))

        let outcome = await Conversion.run(
            plan, settings: Settings(), excluded: "Excluded: pattern slot 5")

        #expect(outcome.note?.contains("fixture 2.mid") == true)
        #expect(outcome.note?.contains("Excluded: pattern slot 5") == true)
    }

    /// Nothing unticked, nothing said.
    @Test func afullConversionCarriesNoExclusion() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "project_5.KeyStepPro")
        let plan = Conversion.plan(
            .toMIDI(source), named: "fixture",
            into: Destination(directory: directory, note: nil))

        let outcome = await Conversion.run(plan, settings: Settings())

        #expect(outcome.note == nil)
    }

    /// The run the exclusion explains is the one that fails.
    @Test func afailedRunStillNamesWhatWasLeftOut() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "project_5.KeyStepPro")
        let plan = Conversion.plan(
            .toMIDI(source), named: "fixture",
            into: Destination(directory: directory, note: nil))

        // One empty slot: the runner refuses rather than writing an empty file.
        let outcome = await Conversion.run(
            plan, settings: Settings(cells: [1: [16]]),
            excluded: "Excluded: pattern slots 1, 2")

        #expect(outcome.failed)
        #expect(outcome.note == "Excluded: pattern slots 1, 2")
    }

    @Test func afailureCarriesTheMessageWithoutTheCommandPrefix() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appending(path: "absent.mid")
        let plan = Conversion.plan(
            .toProject(missing), named: "absent",
            into: Destination(directory: directory, note: nil))

        let outcome = await Conversion.run(plan, settings: Settings())

        #expect(outcome.failed)
        #expect(outcome.written.isEmpty)
        #expect(!outcome.wroteFile)
        // The runner spells failures "<prog>: <message>" for a terminal; the window drops the prefix.
        #expect(!outcome.headline.hasPrefix("ksp-swift-cli"))
        #expect(!outcome.headline.isEmpty)
    }

    /// Fabricated rather than run: nothing writes more than one file until split lands (#130), and
    /// this is the plumbing that will carry it when it does.
    @Test func everyDestinationOfARunIsKeptInTheOrderItWasWritten() {
        let first = URL(filePath: "/tmp/song-track-1.mid")
        let second = URL(filePath: "/tmp/song-track-2.mid")

        let outcome = Conversion.outcome(
            from: RunResult(code: 0, destinations: [first, second]), note: nil, excluded: nil,
            dryRun: false)

        #expect(outcome.written == [first, second])
        #expect(!outcome.failed)
        #expect(outcome.wroteFile)
    }

    /// One file still reads exactly as it did before the outcome went plural.
    @Test func oneWrittenFileReadsAsItsNameAndSeveralAsACount() {
        let one = Outcome(
            written: [URL(filePath: "/tmp/song.mid")], headline: "", report: Report(), note: nil)
        let two = Outcome(
            written: [URL(filePath: "/tmp/a.mid"), URL(filePath: "/tmp/b.mid")], headline: "",
            report: Report(), note: nil)
        let none = Outcome(written: [], headline: "", report: Report(), note: nil)

        #expect(one.resultLine == "song.mid")
        #expect(two.resultLine == "2 files written")
        #expect(none.resultLine == "Nothing was written")

        #expect(one.previewLine == "Would write song.mid")
        #expect(two.previewLine == "Would write 2 files")
        #expect(none.previewLine == "Nothing would be written")
    }
}

/// Reading a dropped project so the staged view can show what is in it.
@Suite struct ConversionSummaryTests {
    /// The one end-to-end read: the app reaches the shipped runner, and what comes back is the
    /// structural summary rather than any rendered text.
    @Test func summarisingAProjectReportsItsTracksAndPatterns() async throws {
        let state = await Conversion.summarise(
            RepoData.projectFiles.appending(path: "project_5.KeyStepPro"))

        guard case .ready(let summary) = state else {
            Issue.record("a readable project should have been summarised, got \(state)")
            return
        }
        #expect(summary.sourceName == "project_5.KeyStepPro")
        #expect(summary.tracks.count == 4)
        #expect(summary.tracks.allSatisfy { $0.patterns.count == 16 })
        #expect(!summary.isEmpty)
    }

    /// An empty project still summarises: the staged view wants four tracks of dimmed slots, not a
    /// failure.
    @Test func anemptyProjectSummarisesAsEmptyRatherThanFailing() async throws {
        let state = await Conversion.summarise(
            RepoData.projectFiles.appending(path: "user_empty_project.KeyStepPro"))

        guard case .ready(let summary) = state else {
            Issue.record("an empty project should still have been summarised, got \(state)")
            return
        }
        #expect(summary.tracks.count == 4)
        #expect(summary.isEmpty)
    }

    /// A file named like a project that is not one: the window shows why, not an empty list.
    @Test func anunreadableProjectComesBackAsAFailureNamingTheFile() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broken = directory.appending(path: "broken.KeyStepPro")
        try Data("not a project".utf8).write(to: broken)

        let state = await Conversion.summarise(broken)

        guard case .failed(let message) = state else {
            Issue.record("an unreadable project should have failed, got \(state)")
            return
        }
        #expect(message.contains("broken.KeyStepPro"))
        // The runner spells failures "<prog>: <message>" for a terminal; the window has none.
        #expect(!message.hasPrefix("ksp-swift-cli"))
    }
}
