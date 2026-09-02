import Foundation
import Testing

@testable import KSPApp

@MainActor
@Suite struct AppModelTests {
    /// A class so the model and the test share the one instance.
    private final class RevealLog {
        var revealed: [[URL]] = []
    }

    /// Destinations the test owns, so nothing reaches MCC's Templates folder.
    private func model(writingInto directory: URL, revealing log: RevealLog = RevealLog())
        -> AppModel
    {
        AppModel(
            store: FolderStore(defaults: volatileDefaults()),
            settingsStore: advancedSettings(),
            destination: { _, _ in Destination(directory: directory, note: nil) },
            reveal: { log.revealed.append($0) }, chooseFolder: { _ in nil })
    }

    private var midiFixture: URL { RepoData.projectFiles.appending(path: "m6-test-file.mid") }

    private var projectFixture: URL {
        RepoData.projectFiles.appending(path: "project_5.KeyStepPro")
    }

    @Test func adropStagesTheFileAndWritesNothing() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)

        model.accept(midiFixture)

        let staged = try #require(model.staged, "the drop should have been staged")
        #expect(staged.job == .toProject(midiFixture))
        #expect(model.name == "m6-test-file")
        #expect(
            model.plan(for: staged.job).target
                == directory.appending(path: "m6-test-file.KeyStepPro"))
        #expect(staged.preview == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func thePlanFollowsTheNameAsItIsTyped() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.accept(midiFixture)

        model.name = "My Song"

        let staged = try #require(model.staged)
        #expect(
            model.plan(for: staged.job).target == directory.appending(path: "My Song.KeyStepPro"))
    }

    @Test func convertingWritesUnderTheNameThatWasTyped() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.accept(midiFixture)
        model.name = "My Song"

        await model.convert()

        guard case .done(let outcome) = model.phase else {
            Issue.record("a conversion should have finished in the result view")
            return
        }
        let written = try #require(
            outcome.written.first, "conversion failed: \(outcome.headline)")
        #expect(written == directory.appending(path: "My Song.KeyStepPro"))
        #expect(FileManager.default.fileExists(atPath: written.path))
    }

    @Test func atypedNameThatIsTakenStepsAsideAndSaysSo() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        try touch(directory, "My Song.KeyStepPro")
        model.accept(midiFixture)

        model.name = "My Song"

        let plan = model.plan(for: try #require(model.staged).job)
        #expect(plan.target.lastPathComponent == "My Song 2.KeyStepPro")
        #expect(plan.note?.contains("My Song 2.KeyStepPro") == true)
    }

    @Test func thetypedNameNamesTheFolderWhenTheExportSplits() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.accept(projectFixture)
        model.settings.splitPerPattern = true

        model.name = "My Song"

        let plan = model.plan(for: try #require(model.staged).job)
        #expect(plan.intoFolder)
        #expect(plan.target == directory.appending(path: "My Song"))
    }

    @Test func anexportPlansOneFileUntilTheControlIsSwitched() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.accept(projectFixture)

        let plan = model.plan(for: try #require(model.staged).job)
        #expect(!plan.intoFolder)
        #expect(plan.target == directory.appending(path: "project_5.mid"))
    }

    @Test func editingTheNameDiscardsADryRunPreview() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.settings.dryRun = true
        model.accept(midiFixture)
        await model.convert()
        #expect(try #require(model.staged).preview != nil)

        model.discardPreview()

        #expect(try #require(model.staged).preview == nil)
    }

    @Test func cancelReturnsToIdleWithoutWriting() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.accept(midiFixture)

        model.cancel()

        guard case .idle = model.phase else {
            Issue.record("cancel should have returned the window to idle")
            return
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func anunconvertibleDropIsRefusedOutright() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)

        model.accept(URL(filePath: "/tmp/notes.txt"))

        guard case .done(let outcome) = model.phase else {
            Issue.record("an unconvertible drop should have reported a failure")
            return
        }
        #expect(outcome.failed)
        #expect(outcome.written.isEmpty)
        #expect(model.staged == nil)
    }

    @Test func convertingWritesTheFileAndFinishesTheJob() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = RevealLog()
        let model = model(writingInto: directory, revealing: log)
        model.accept(midiFixture)

        await model.convert()

        guard case .done(let outcome) = model.phase else {
            Issue.record("a conversion should have finished in the result view")
            return
        }
        let written = try #require(
            outcome.written.first, "conversion failed: \(outcome.headline)")
        #expect(outcome.wroteFile)
        #expect(FileManager.default.fileExists(atPath: written.path))
        #expect(log.revealed == [outcome.written])
    }

    @Test func adryRunKeepsTheFileStagedAndWritesNothing() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = RevealLog()
        let model = model(writingInto: directory, revealing: log)
        model.settings.dryRun = true
        model.accept(midiFixture)

        await model.convert()

        let staged = try #require(model.staged, "a dry run should leave the file staged")
        #expect(log.revealed.isEmpty)
        let preview = try #require(staged.preview, "a dry run should report what it would write")
        #expect(preview.dryRun)
        #expect(!preview.failed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func turningTheDryRunOffAndConvertingAgainWritesTheFile() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.settings.dryRun = true
        model.accept(midiFixture)
        await model.convert()

        model.settings.dryRun = false
        await model.convert()

        guard case .done(let outcome) = model.phase else {
            Issue.record("the second conversion should have finished in the result view")
            return
        }
        let written = try #require(
            outcome.written.first, "conversion failed: \(outcome.headline)")
        // The dry run wrote nothing, so the real one gets the plain name rather than "… 2".
        #expect(written == directory.appending(path: "m6-test-file.KeyStepPro"))
        #expect(FileManager.default.fileExists(atPath: written.path))
    }
}

@MainActor
@Suite struct AppModelFolderTests {
    private var midiFixture: URL { RepoData.projectFiles.appending(path: "m6-test-file.mid") }

    /// A chosen folder is exactly what keeps `forProjects` away from MCC's Templates folder.
    private func model(picking picked: URL?, over defaults: UserDefaults) -> AppModel {
        AppModel(
            store: FolderStore(defaults: defaults),
            settingsStore: SettingsStore(defaults: defaults), reveal: { _ in },
            chooseFolder: { _ in picked })
    }

    private func withFolder(_ body: (UserDefaults, URL) throws -> Void) throws {
        try withVolatileDefaults { defaults in
            let chosen = try tempDirectory()
            defer { try? FileManager.default.removeItem(at: chosen) }
            try body(defaults, chosen)
        }
    }

    @Test func achosenProjectFolderIsWhereTheStagedFileWouldLand() throws {
        try withFolder { defaults, chosen in
            let model = model(picking: chosen, over: defaults)

            model.choose(.project)
            model.accept(midiFixture)

            #expect(model.folders.project == chosen)
            let plan = model.plan(for: try #require(model.staged).job)
            #expect(plan.target == chosen.appending(path: "m6-test-file.KeyStepPro"))
        }
    }

    @Test func achosenMIDIFolderTakesTheExportWithoutMovingProjects() throws {
        try withFolder { defaults, chosen in
            let model = model(picking: chosen, over: defaults)

            model.choose(.midi)

            #expect(model.folders.midi == chosen)
            #expect(model.folders.project == nil)
        }
    }

    @Test func cancellingThePanelLeavesTheFolderAlone() {
        withVolatileDefaults { defaults in
            let model = model(picking: nil, over: defaults)

            model.choose(.project)

            #expect(model.folders.project == nil)
        }
    }

    @Test func achoiceIsRememberedForTheNextLaunch() throws {
        try withFolder { defaults, chosen in
            model(picking: chosen, over: defaults).choose(.project)

            // A second model over the same domain is what the next launch builds.
            let relaunched = model(picking: nil, over: defaults)

            #expect(relaunched.folders.project == chosen)
        }
    }

    @Test func returningToTheDefaultIsAlsoRemembered() throws {
        try withFolder { defaults, chosen in
            let model = model(picking: chosen, over: defaults)
            model.choose(.project)
            model.choose(.midi)

            model.useDefault(for: .project)

            #expect(model.folders.project == nil)
            #expect(model.folders.midi == chosen)
            #expect(self.model(picking: nil, over: defaults).folders.project == nil)
        }
    }

    @Test func awarningStandsWhileAProjectFolderIsSet() throws {
        try withFolder { defaults, chosen in
            let model = model(picking: chosen, over: defaults)
            #expect(model.mccWarning == nil)

            model.choose(.project)
            #expect(model.mccWarning != nil)

            model.useDefault(for: .project)
            #expect(model.mccWarning == nil)
        }
    }

    @Test func achosenMIDIFolderIsNotWarnedAbout() throws {
        try withFolder { defaults, chosen in
            let model = model(picking: chosen, over: defaults)

            model.choose(.midi)

            #expect(model.mccWarning == nil)
        }
    }
}

@MainActor
@Suite struct AppModelSummaryTests {
    private func model() -> AppModel {
        AppModel(
            store: FolderStore(defaults: volatileDefaults()),
            settingsStore: advancedSettings(),
            destination: { _, _ in
                Destination(directory: FileManager.default.temporaryDirectory, note: nil)
            },
            reveal: { _ in }, chooseFolder: { _ in nil })
    }

    private var projectFixture: URL {
        RepoData.projectFiles.appending(path: "project_5.KeyStepPro")
    }

    private var midiFixture: URL {
        RepoData.projectFiles.appending(path: "m6-test-file.mid")
    }

    @Test func adroppedProjectIsStagedLoadingAndThenSummarised() async throws {
        let model = model()

        model.accept(projectFixture)

        #expect(try #require(model.staged).summary == .loading)

        await model.summarise()

        guard case .project(let summary) = try #require(model.staged).summary else {
            Issue.record("the staged project should have been summarised")
            return
        }
        #expect(summary.sourceName == "project_5.KeyStepPro")
        #expect(summary.tracks.count == 4)
    }

    @Test func adroppedMIDIFileIsStagedLoadingAndThenSummarised() async throws {
        let model = model()

        model.accept(midiFixture)

        #expect(try #require(model.staged).summary == .loading)

        await model.summarise()

        guard case .song(let summary) = try #require(model.staged).summary else {
            Issue.record("the staged MIDI file should have been summarised")
            return
        }
        #expect(summary.sourceName == "m6-test-file.mid")
        #expect(!summary.tracks.isEmpty)
    }

    /// Four of its six tracks hold notes, so the default ticks them all and nothing is refused.
    @Test func asummarisedSongBlocksNothing() async throws {
        let model = model()
        model.accept(midiFixture)

        await model.summarise()

        #expect(model.blockReason == nil)
    }

    @Test func asummarisedSongTicksTheTracksThatHoldNotes() async throws {
        let model = model()
        model.accept(midiFixture)

        await model.summarise()

        let selection = try #require(model.staged).sourceSelection
        #expect([3, 4, 5, 6].allSatisfy { selection.isTicked($0) })
        #expect(!selection.isTicked(1))
        #expect(selection.spec == nil)
    }

    /// The middle row is the track list's, so the sidebar offers it only once a track fills it.
    @Test func thenamedTrackRowIsOfferedOnlyWhileOneIsNamed() async throws {
        let model = model()
        model.accept(midiFixture)
        await model.summarise()
        #expect(model.drumChoices == [.automatic, .none])
        #expect(model.drumChoice == .automatic)

        model.send(sourceTrack: 3, to: .drums)

        #expect(model.drumChoices == [.automatic, .source(3), .none])
        #expect(model.drumChoice == .source(3))
    }

    /// The ambiguous pair never exists in the UI: the sidebar's two clear the track list's choice.
    @Test(arguments: [AppModel.DrumChoice.automatic, .none])
    func choosingInTheSidebarClearsTheDrumsDestination(choice: AppModel.DrumChoice) async throws {
        let model = model()
        model.accept(midiFixture)
        await model.summarise()
        model.send(sourceTrack: 3, to: .drums)

        model.drumChoice = choice

        #expect(try #require(model.staged).sourceSelection.drumTrack == nil)
        #expect(try #require(model.staged).sourceSelection.destination(3) == .automatic)
        #expect(model.drumChoice == choice)
    }

    /// `ConvertRunner.run` fails `--drum-track` with `--no-drums` at exit 2, so the two must never
    /// both be set: naming a track leaves None behind.
    @Test func sendingASourceTrackToDrumsLeavesNoneBehind() async throws {
        let model = model()
        model.accept(midiFixture)
        await model.summarise()
        model.drumChoice = .none

        model.send(sourceTrack: 3, to: .drums)

        #expect(model.settings.drums == .automatic)
        let mapped = model.conversionSettings.convertOptions(source: midiFixture, output: nil)
        #expect(mapped.drumTrack == 3)
        #expect(!mapped.noDrums)
    }

    @Test func untickingAsourceTrackDiscardsAdryRunPreview() async throws {
        let model = model()
        model.settings.dryRun = true
        model.accept(midiFixture)
        await model.summarise()
        await model.convert()
        #expect(try #require(model.staged).preview != nil)

        model.toggle(sourceTrack: 3)

        #expect(try #require(model.staged).preview == nil)
        #expect(try #require(model.staged).sourceSelection.spec == "4,5,6")
    }

    @Test func untickingEverySourceTrackBlocksConvert() async throws {
        let model = model()
        model.accept(midiFixture)
        await model.summarise()

        for track in 3...6 { model.toggle(sourceTrack: track) }

        #expect(model.blockReason?.contains("Nothing is ticked") == true)
    }

    /// The ticks are the CLI's own selection, so a run reads what they name and nothing else.
    @Test func adryRunReadsOnlyTheTickedSourceTracks() async throws {
        let model = model()
        model.settings.dryRun = true
        model.accept(midiFixture)
        await model.summarise()
        model.toggle(sourceTrack: 3)
        model.toggle(sourceTrack: 4)

        await model.convert()

        let staged = try #require(model.staged)
        let preview = try #require(staged.preview)
        #expect(preview.headline.contains("track 1"))
        #expect(preview.headline.contains("track 2"))
        #expect(!preview.headline.contains("track 3"))
        #expect(preview.note?.contains("Excluded:") == true)
    }

    @Test func anunreadableMIDIFileStaysStagedAndShowsTheFailure() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broken = directory.appending(path: "broken.mid")
        try Data("not a MIDI file".utf8).write(to: broken)
        let model = model()

        model.accept(broken)
        await model.summarise()

        guard case .failed(let message) = try #require(model.staged).summary else {
            Issue.record("an unreadable MIDI file should have shown its failure")
            return
        }
        #expect(message.contains("broken.mid"))
    }

    @Test func asongArrivingAfterACancelIsDropped() async throws {
        let model = model()
        model.accept(midiFixture)

        let reading = Task { await model.summarise() }
        await Task.yield()
        model.cancel()
        await reading.value

        guard case .idle = model.phase else {
            Issue.record("a cancelled drop should have stayed cancelled")
            return
        }
    }

    @Test func anunreadableProjectStaysStagedAndShowsTheFailure() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broken = directory.appending(path: "broken.KeyStepPro")
        try Data("not a project".utf8).write(to: broken)
        let model = model()

        model.accept(broken)
        await model.summarise()

        guard case .failed(let message) = try #require(model.staged).summary else {
            Issue.record("an unreadable project should have shown its failure")
            return
        }
        #expect(message.contains("broken.KeyStepPro"))
    }

    @Test func asummaryArrivingAfterACancelIsDropped() async throws {
        let model = model()
        model.accept(projectFixture)

        let reading = Task { await model.summarise() }
        await Task.yield()
        model.cancel()
        await reading.value

        guard case .idle = model.phase else {
            Issue.record("a cancelled drop should have stayed cancelled")
            return
        }
    }

    /// The staged view keys its `.task` on this identity, not the path, or a redrop spins forever.
    @Test func redroppingTheSameProjectIsAnewDropAndIsReadAgain() async throws {
        let model = model()
        model.accept(projectFixture)
        await model.summarise()
        let first = try #require(model.staged).id

        model.accept(projectFixture)

        let restaged = try #require(model.staged)
        #expect(restaged.id != first)
        #expect(restaged.summary == .loading)

        await model.summarise()

        guard case .project = try #require(model.staged).summary else {
            Issue.record("the second drop should have been read too")
            return
        }
    }

    @Test func adryRunKeepsTheSummaryItAlreadyHas() async throws {
        let model = model()
        model.accept(projectFixture)
        model.settings.dryRun = true
        await model.summarise()
        let staged = try #require(model.staged)

        await model.convert()

        let after = try #require(model.staged)
        #expect(after.id == staged.id)
        #expect(after.summary == staged.summary)
        #expect(after.preview != nil)
    }

    @Test func summarisingTwiceKeepsTheFirstAnswer() async throws {
        let model = model()
        model.accept(projectFixture)

        await model.summarise()
        let first = try #require(model.staged).summary
        await model.summarise()

        #expect(try #require(model.staged).summary == first)
    }

    @Test func asummarisedProjectStartsFullyTicked() async throws {
        let model = model()
        model.accept(projectFixture)

        await model.summarise()

        let selection = try #require(model.staged).selection
        #expect(selection.selectedCells.isEmpty)
        #expect(selection.isTicked(track: 4, pattern: 16))
        #expect(model.blockReason == nil)
    }

    @Test func anewDropStartsItsTicksAgain() async throws {
        let model = model()
        model.accept(projectFixture)
        await model.summarise()
        model.toggle(track: 2)
        #expect(try #require(model.staged).selection.selectedCells[2] == nil)

        model.accept(projectFixture)
        await model.summarise()

        #expect(try #require(model.staged).selection.selectedCells.isEmpty)
    }

    @Test func untickingSomethingDiscardsAdryRunPreview() async throws {
        let model = model()
        model.accept(projectFixture)
        model.settings.dryRun = true
        await model.summarise()
        await model.convert()
        #expect(try #require(model.staged).preview != nil)

        model.toggle(pattern: 5)

        #expect(try #require(model.staged).preview == nil)
        #expect(
            try #require(model.staged).selection.selectedCells[1] == Set(1...16).subtracting([5]))
    }

    @Test func anemptySelectionBlocksConvert() async throws {
        let model = model()
        model.accept(projectFixture)
        await model.summarise()

        for track in 1...4 { model.toggle(track: track) }

        #expect(model.blockReason?.contains("Nothing is ticked") == true)

        model.toggle(track: 1)

        #expect(model.blockReason == nil)
    }

    @Test func ablockedSelectionConvertsNothing() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            store: FolderStore(defaults: volatileDefaults()),
            settingsStore: advancedSettings(),
            destination: { _, _ in Destination(directory: directory, note: nil) },
            reveal: { _ in }, chooseFolder: { _ in nil })
        model.accept(projectFixture)
        await model.summarise()
        for track in 1...4 { model.toggle(track: track) }

        await model.convert()

        #expect(model.staged != nil, "a blocked drop stays staged")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func adropWithoutAgridIsNeverBlocked() async throws {
        let model = model()

        model.accept(RepoData.projectFiles.appending(path: "m6-test-file.mid"))
        await model.summarise()
        #expect(model.blockReason == nil)

        model.accept(projectFixture)
        #expect(model.blockReason == nil)
    }

    @Test func convertingWithOneCellUntickedLeavesOnlyThatCellOut() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            store: FolderStore(defaults: volatileDefaults()),
            settingsStore: advancedSettings(),
            destination: { _, _ in Destination(directory: directory, note: nil) },
            reveal: { _ in }, chooseFolder: { _ in nil })
        model.accept(projectFixture)
        await model.summarise()

        model.toggle(track: 1, pattern: 1)
        await model.convert()

        guard case .done(let outcome) = model.phase else {
            Issue.record("a conversion should have finished in the result view")
            return
        }
        #expect(!outcome.written.isEmpty, "conversion failed: \(outcome.headline)")
        #expect(outcome.headline.contains("Track 3"))
        #expect(!outcome.headline.contains("Track 1"))
        #expect(outcome.note == "Excluded: Track 1 (drum) slot 1")
    }

    @Test func convertingAtickedProjectExportsOnlyWhatIsTickedAndSaysWhatIsNot() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            store: FolderStore(defaults: volatileDefaults()),
            settingsStore: advancedSettings(),
            destination: { _, _ in Destination(directory: directory, note: nil) },
            reveal: { _ in }, chooseFolder: { _ in nil })
        model.accept(projectFixture)
        await model.summarise()

        model.toggle(track: 2)
        await model.convert()

        guard case .done(let outcome) = model.phase else {
            Issue.record("a conversion should have finished in the result view")
            return
        }
        #expect(try #require(outcome.written.first).lastPathComponent == "project_5.mid")
        #expect(outcome.note?.contains("Excluded: Track 2") == true)
        #expect(!outcome.headline.contains("Track 2"))
    }
}
