import Foundation
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

        let written = try #require(outcome.written, "conversion failed: \(outcome.headline)")
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
        #expect(outcome.written == plan.target)
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

    @Test func afailureCarriesTheMessageWithoutTheCommandPrefix() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appending(path: "absent.mid")
        let plan = Conversion.plan(
            .toProject(missing), named: "absent",
            into: Destination(directory: directory, note: nil))

        let outcome = await Conversion.run(plan, settings: Settings())

        #expect(outcome.failed)
        #expect(outcome.written == nil)
        #expect(!outcome.wroteFile)
        // The runner spells failures "<prog>: <message>" for a terminal; the window drops the prefix.
        #expect(!outcome.headline.hasPrefix("ksp-swift-cli"))
        #expect(!outcome.headline.isEmpty)
    }
}
