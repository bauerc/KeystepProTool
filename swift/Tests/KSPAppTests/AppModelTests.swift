import Foundation
import Testing

@testable import KSPApp

/// The staged phase: a drop no longer writes, and the write happens when Convert says so.
@MainActor
@Suite struct AppModelTests {
    /// Destinations the test owns, so nothing reaches MCC's Templates folder, and a reveal that
    /// does nothing, so a test run opens no Finder windows.
    private func model(writingInto directory: URL) -> AppModel {
        AppModel(
            destination: { _ in Destination(directory: directory, note: nil) }, reveal: { _ in })
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
        let written = try #require(outcome.written, "conversion failed: \(outcome.headline)")
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
        #expect(model.staged == nil)
    }

    @Test func convertingWritesTheFileAndFinishesTheJob() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.accept(midiFixture)

        await model.convert()

        guard case .done(let outcome) = model.phase else {
            Issue.record("a conversion should have finished in the result view")
            return
        }
        let written = try #require(outcome.written, "conversion failed: \(outcome.headline)")
        #expect(outcome.wroteFile)
        #expect(FileManager.default.fileExists(atPath: written.path))
    }

    /// A dry run is a look at what would happen, so the file stays staged.
    @Test func adryRunKeepsTheFileStagedAndWritesNothing() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.settings.dryRun = true
        model.accept(midiFixture)

        await model.convert()

        let staged = try #require(model.staged, "a dry run should leave the file staged")
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
        let written = try #require(outcome.written, "conversion failed: \(outcome.headline)")
        // The dry run wrote nothing, so the real one gets the plain name rather than "… 2".
        #expect(written == directory.appending(path: "m6-test-file.KeyStepPro"))
        #expect(FileManager.default.fileExists(atPath: written.path))
    }
}
