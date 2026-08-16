import Foundation
import Testing

@testable import KSPApp

/// The staged phase: a drop no longer writes, and the write happens when Convert says so.
@MainActor
@Suite struct AppModelTests {
    /// A model whose destinations are a directory the test owns, so nothing reaches MCC's Templates
    /// folder or `~/Downloads` on the machine running this -- and whose Finder reveal does nothing,
    /// so a test run does not open windows.
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
        #expect(staged.plan.job == .toProject(midiFixture))
        #expect(staged.plan.target == directory.appending(path: "m6-test-file.KeyStepPro"))
        #expect(staged.preview == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
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

    /// A dry run is a look at what would happen, so the file stays staged: switch the toggle off,
    /// press Convert again and it is written for real.
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
