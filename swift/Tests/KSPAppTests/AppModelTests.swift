import Foundation
import Testing

@testable import KSPApp

/// The staged phase: a drop no longer writes, and the write happens when Convert says so.
@MainActor
@Suite struct AppModelTests {
    /// What was handed to Finder, instead of handing it to Finder. A class so the model and the
    /// test share the one instance.
    private final class RevealLog {
        var revealed: [[URL]] = []
    }

    /// Destinations the test owns, so nothing reaches MCC's Templates folder; a reveal that records
    /// rather than opening a window; and a folder panel that never opens.
    private func model(writingInto directory: URL, revealing log: RevealLog = RevealLog())
        -> AppModel
    {
        AppModel(
            store: FolderStore(defaults: volatileDefaults()),
            destination: { _, _ in Destination(directory: directory, note: nil) },
            reveal: { log.revealed.append($0) }, chooseFolder: { _ in nil })
    }

    private var midiFixture: URL { RepoData.projectFiles.appending(path: "m6-test-file.mid") }

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

    /// The name is typed before the write, so the file is created under it rather than moved
    /// afterwards -- and the destination on screen follows each keystroke.
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

    /// The never-overwrite ladder now applies to the name the user chose, not the source's stem.
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

    /// A dry run describes one name, so editing the name drops it rather than leaving a stale
    /// preview on screen.
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

    /// Refused before a runner is called, and before anything is staged.
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
        // Finder is asked to select the whole list, so a split run reveals every file of it.
        #expect(log.revealed == [outcome.written])
    }

    /// A dry run is a look at what would happen, so the file stays staged.
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

    /// The same file, dry then wet, is the flow the toggle exists for.
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

/// The two destination folders: chosen independently, obeyed by the staged plan, and remembered.
@MainActor
@Suite struct AppModelFolderTests {
    private var midiFixture: URL { RepoData.projectFiles.appending(path: "m6-test-file.mid") }

    /// The real placement rules, so a chosen folder is tested through the routing the app uses --
    /// safe because a chosen folder is exactly what keeps `forProjects` away from MCC's.
    private func model(picking picked: URL?, over defaults: UserDefaults) -> AppModel {
        AppModel(
            store: FolderStore(defaults: defaults), reveal: { _ in }, chooseFolder: { _ in picked })
    }

    /// A defaults domain and a folder to pick, both this test's own and both cleaned up after it.
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

    /// The MIDI folder is set on its own and does not disturb where a project goes.
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

    /// The warning stands while the folder is set, which is what "at the moment of choosing" has to
    /// mean for a choice that outlives the moment.
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

    /// A MIDI folder says nothing about MCC: the Project Browser never lists `.mid` files.
    @Test func achosenMIDIFolderIsNotWarnedAbout() throws {
        try withFolder { defaults, chosen in
            let model = model(picking: chosen, over: defaults)

            model.choose(.midi)

            #expect(model.mccWarning == nil)
        }
    }
}

/// What a dropped project shows about itself before Convert is pressed.
@MainActor
@Suite struct AppModelSummaryTests {
    private func model() -> AppModel {
        AppModel(
            store: FolderStore(defaults: volatileDefaults()),
            destination: { _, _ in
                Destination(directory: FileManager.default.temporaryDirectory, note: nil)
            },
            reveal: { _ in }, chooseFolder: { _ in nil })
    }

    private var projectFixture: URL {
        RepoData.projectFiles.appending(path: "project_5.KeyStepPro")
    }

    /// The drop stages immediately and the read follows, so a 3.5 MB parse never happens between
    /// the file leaving the cursor and the window redrawing.
    @Test func adroppedProjectIsStagedLoadingAndThenSummarised() async throws {
        let model = model()

        model.accept(projectFixture)

        #expect(try #require(model.staged).summary == .loading)

        await model.summarise()

        guard case .ready(let summary) = try #require(model.staged).summary else {
            Issue.record("the staged project should have been summarised")
            return
        }
        #expect(summary.sourceName == "project_5.KeyStepPro")
        #expect(summary.tracks.count == 4)
    }

    /// The other direction has no project to read: the staged view shows the plan and nothing else.
    @Test func adroppedMIDIFileHasNothingToSummarise() async throws {
        let model = model()

        model.accept(RepoData.projectFiles.appending(path: "m6-test-file.mid"))
        await model.summarise()

        #expect(try #require(model.staged).summary == .absent)
    }

    /// A project that will not read stays staged and says why -- the window must not offer an empty
    /// list instead.
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

    /// The read outlives the drop it was for. Whichever guard catches it, a cancelled drop must not
    /// be reopened by a summary that arrives afterwards.
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

    /// Dropping the same file again is a new drop, so it is a new read. The staged view keys its
    /// `.task` on this identity: were it the path, the second drop would wait for a read that never
    /// started and show a spinner for good.
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

        guard case .ready = try #require(model.staged).summary else {
            Issue.record("the second drop should have been read too")
            return
        }
    }

    /// A dry run is the same drop still staged, so its summary is not read a second time.
    @Test func adryRunKeepsTheSummaryItAlreadyHas() async throws {
        let model = model()
        model.settings.dryRun = true
        model.accept(projectFixture)
        await model.summarise()
        let staged = try #require(model.staged)

        await model.convert()

        let after = try #require(model.staged)
        #expect(after.id == staged.id)
        #expect(after.summary == staged.summary)
        #expect(after.preview != nil)
    }

    /// Reading is idempotent: the view drives it from `.task`, which can run again for the same
    /// staged file.
    @Test func summarisingTwiceKeepsTheFirstAnswer() async throws {
        let model = model()
        model.accept(projectFixture)

        await model.summarise()
        let first = try #require(model.staged).summary
        await model.summarise()

        #expect(try #require(model.staged).summary == first)
    }
}
