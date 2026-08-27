import Foundation
import KSPKit
import KSPMIDI
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

    @Test(arguments: ["notes.txt", "song", "song.wav"])
    func anythingElseIsRefused(name: String) {
        #expect(Conversion.job(for: URL(filePath: "/tmp/\(name)")) == nil)
    }

    @Test func theResultExtensionIsTheOppositeOfWhatWasDropped() {
        #expect(Job.toProject(URL(filePath: "/a.mid")).extensionOfResult == "KeyStepPro")
        #expect(Job.toMIDI(URL(filePath: "/a.KeyStepPro")).extensionOfResult == "mid")
    }

    @Test func aPlanNamesWhereTheResultWillLand() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "m6-test-file.mid")

        let plan = Conversion.plan(
            .toProject(source), named: "fixture",
            into: Destination(directory: directory, note: nil))

        #expect(plan.target == directory.appending(path: "fixture.KeyStepPro"))
        #expect(!plan.intoFolder)
        #expect(plan.note == nil)
    }

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

    @Test func asplitPlanClaimsAFolderRatherThanAFile() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "project_5.KeyStepPro")

        let plan = Conversion.plan(
            .toMIDI(source), named: "fixture",
            into: Destination(directory: directory, note: nil), splitting: true)

        #expect(plan.intoFolder)
        #expect(plan.target == directory.appending(path: "fixture"))
        #expect(plan.target.pathExtension.isEmpty)
        #expect(plan.note == nil)
    }

    @Test func asplitPlanStepsAsideFromAnExistingFolderAndSaysSo() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "project_5.KeyStepPro")
        try FileManager.default.createDirectory(
            at: directory.appending(path: "fixture"), withIntermediateDirectories: true)

        let plan = Conversion.plan(
            .toMIDI(source), named: "fixture",
            into: Destination(directory: directory, note: nil), splitting: true)

        #expect(plan.target.lastPathComponent == "fixture 2")
        #expect(plan.note?.contains("fixture 2") == true)
    }

    @Test func animportIgnoresSplitting() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "m6-test-file.mid")

        let plan = Conversion.plan(
            .toProject(source), named: "fixture",
            into: Destination(directory: directory, note: nil), splitting: true)

        #expect(!plan.intoFolder)
        #expect(plan.target == directory.appending(path: "fixture.KeyStepPro"))
    }

    @Test func asplitExportFillsItsFolderAndReportsEveryFile() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "project_5.KeyStepPro")
        let plan = Conversion.plan(
            .toMIDI(source), named: "fixture",
            into: Destination(directory: directory, note: nil), splitting: true)

        let outcome = await Conversion.run(plan, settings: Settings(splitPerPattern: true))

        #expect(!outcome.failed, "export failed: \(outcome.headline)")
        #expect(outcome.written.count > 1)
        // Compared by path: `deletingLastPathComponent()` leaves a trailing slash the URL has not.
        #expect(
            outcome.written.allSatisfy {
                $0.deletingLastPathComponent().path == plan.target.path
            })
        #expect(
            outcome.written.map(\.lastPathComponent)
                .contains("project_5_track1_pattern1.mid"))
        #expect(outcome.written.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(outcome.folder == plan.target)
    }

    @Test func asplitExportOfOneSlotStillNamesItsFolder() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "project_5.KeyStepPro")
        let plan = Conversion.plan(
            .toMIDI(source), named: "fixture",
            into: Destination(directory: directory, note: nil), splitting: true)

        let outcome = await Conversion.run(
            plan, settings: Settings(cells: [3: [1]], splitPerPattern: true))

        #expect(!outcome.failed, "export failed: \(outcome.headline)")
        #expect(outcome.written.count == 1)
        #expect(outcome.folder == plan.target)
    }

    @Test func aplainExportReportsNoFolder() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "project_5.KeyStepPro")
        let plan = Conversion.plan(
            .toMIDI(source), named: "fixture",
            into: Destination(directory: directory, note: nil))

        let outcome = await Conversion.run(plan, settings: Settings())

        #expect(!outcome.failed)
        #expect(outcome.folder == nil)
    }

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
        #expect(!outcome.wroteFile)
        #expect(outcome.written == [plan.target])
        #expect(!FileManager.default.fileExists(atPath: plan.target.path))
    }

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
        #expect(!outcome.headline.hasPrefix("ksp-swift-cli"))
        #expect(!outcome.headline.isEmpty)
    }

    /// The fragments are partial on purpose: the wording is a parity contract owned by `KSPKit`.
    @Test(
        arguments: [
            (Settings.StepSkip.auto, "were rendered as repeats", "rendered as 4 repeats"),
            (Settings.StepSkip.one, "renders one and includes them all", "one pass was rendered"),
        ])
    func theStepSkipChoiceIsReportedInTheResult(
        choice: Settings.StepSkip, collapsed: String, each: String
    ) async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "project_5.KeyStepPro")
        let plan = Conversion.plan(
            .toMIDI(source), named: "fixture",
            into: Destination(directory: directory, note: nil))
        var settings = Settings(dryRun: true)
        settings.stepSkip = choice

        let outcome = await Conversion.run(plan, settings: settings)

        #expect(!outcome.failed)
        let summary = outcome.findings(verbose: false).filter { $0.contains("16/32/48/64") }
        #expect(summary.count == 1)
        #expect(summary.first?.contains(collapsed) == true)

        let sites = outcome.findings(verbose: true).filter { $0.contains("16/32/48/64") }
        #expect(!sites.isEmpty)
        #expect(sites.allSatisfy { $0.contains(each) })
    }

    @Test(arguments: ["project_5.KeyStepPro", "project_9.KeyStepPro", "initial_project.KeyStepPro"])
    func thelengthCountsThePatternsTheExportLaysDown(name: String) throws {
        let project = try Reader.load(contentsOf: RepoData.projectFiles.appending(path: name))
        let summary = ProjectSummary(project)

        let length = ExportLength(
            summary, selection: GridSelection(summary), repeatCount: 1, isSplit: false)
        let laid = Set(try MIDIExport.renderProject(project).map(\.patternNumber))

        #expect(length.patterns == laid.count)
    }

    @Test(arguments: ["project_5.KeyStepPro", "project_9.KeyStepPro"])
    func asplitFileHoldsExactlyOnePattern(name: String) throws {
        let project = try Reader.load(contentsOf: RepoData.projectFiles.appending(path: name))

        let files = try MIDIExport.exportSplit(project)

        #expect(!files.isEmpty)
        #expect(files.allSatisfy { $0.patternNumbers.count == 1 })
    }

    @Test func therepeatCountReachesTheFileThatIsWritten() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "project_5.KeyStepPro")

        func exported(_ settings: Settings, named name: String) async throws -> Data {
            let plan = Conversion.plan(
                .toMIDI(source), named: name, into: Destination(directory: directory, note: nil))
            let outcome = await Conversion.run(plan, settings: settings)
            #expect(!outcome.failed)
            return try Data(contentsOf: try #require(outcome.written.first))
        }

        var thrice = Settings()
        thrice.repeatCount = 3
        var once = Settings()
        once.repeatCount = 1

        let byDefault = try await exported(Settings(), named: "default")

        #expect(try await exported(once, named: "once") == byDefault)
        #expect(try await exported(thrice, named: "thrice").count > byDefault.count)
    }

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

@Suite struct ConversionSummaryTests {
    @Test func summarisingAProjectReportsItsTracksAndPatterns() async throws {
        let state = await Conversion.summarise(
            .toMIDI(RepoData.projectFiles.appending(path: "project_5.KeyStepPro")))

        guard case .project(let summary) = state else {
            Issue.record("a readable project should have been summarised, got \(state)")
            return
        }
        #expect(summary.sourceName == "project_5.KeyStepPro")
        #expect(summary.tracks.count == 4)
        #expect(summary.tracks.allSatisfy { $0.patterns.count == 16 })
        #expect(!summary.isEmpty)
    }

    @Test func anemptyProjectSummarisesAsEmptyRatherThanFailing() async throws {
        let state = await Conversion.summarise(
            .toMIDI(RepoData.projectFiles.appending(path: "user_empty_project.KeyStepPro")))

        guard case .project(let summary) = state else {
            Issue.record("an empty project should still have been summarised, got \(state)")
            return
        }
        #expect(summary.tracks.count == 4)
        #expect(summary.isEmpty)
    }

    @Test func anunreadableProjectComesBackAsAFailureNamingTheFile() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broken = directory.appending(path: "broken.KeyStepPro")
        try Data("not a project".utf8).write(to: broken)

        let state = await Conversion.summarise(.toMIDI(broken))

        guard case .failed(let message) = state else {
            Issue.record("an unreadable project should have failed, got \(state)")
            return
        }
        #expect(message.contains("broken.KeyStepPro"))
        #expect(!message.hasPrefix("ksp-swift-cli"))
    }

    @Test func summarisingAMIDIFileReportsItsSourceTracks() async throws {
        let state = await Conversion.summarise(
            .toProject(RepoData.projectFiles.appending(path: "test_file.mid")))

        guard case .song(let summary) = state else {
            Issue.record("a readable MIDI file should have been summarised, got \(state)")
            return
        }
        #expect(summary.sourceName == "test_file.mid")
        #expect(!summary.tracks.isEmpty)
        #expect(!summary.isEmpty)
    }

    @Test func anunreadableMIDIFileComesBackAsAFailureNamingTheFile() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broken = directory.appending(path: "broken.mid")
        try Data("not a MIDI file".utf8).write(to: broken)

        let state = await Conversion.summarise(.toProject(broken))

        guard case .failed(let message) = state else {
            Issue.record("an unreadable MIDI file should have failed, got \(state)")
            return
        }
        #expect(message.contains("broken.mid"))
        #expect(!message.hasPrefix("ksp-swift-cli"))
    }

    @Test func amissingMIDIFileFailsRatherThanSummarisingNothing() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = await Conversion.summarise(.toProject(directory.appending(path: "gone.mid")))

        guard case .failed = state else {
            Issue.record("a missing MIDI file should have failed, got \(state)")
            return
        }
    }
}
