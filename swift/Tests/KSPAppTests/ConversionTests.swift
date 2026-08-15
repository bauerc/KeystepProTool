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

    /// The one end-to-end run, and the point of it is that the app reaches the *shipped* runner and
    /// finds the bundled 3.5 MB template through `Bundle.module` -- neither of which a unit test of
    /// the naming rules would catch.
    @Test func convertingAMIDIFileWritesAProjectWhereItWasAsked() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "m6-test-file.mid")
        let destination = Destination(directory: directory, note: nil)

        let outcome = await Conversion.run(.toProject(source), named: "fixture", into: destination)

        let written = try #require(outcome.written, "conversion failed: \(outcome.headline)")
        #expect(!outcome.failed)
        #expect(written == directory.appending(path: "fixture.KeyStepPro"))
        #expect(FileManager.default.fileExists(atPath: written.path))
    }

    /// A second conversion of the same source under the same name must not destroy the first.
    @Test func asecondConversionStepsAsideAndSaysSo() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = RepoData.projectFiles.appending(path: "m6-test-file.mid")
        let destination = Destination(directory: directory, note: nil)
        try touch(directory, "fixture.KeyStepPro")

        let outcome = await Conversion.run(.toProject(source), named: "fixture", into: destination)

        let written = try #require(outcome.written, "conversion failed: \(outcome.headline)")
        #expect(written.lastPathComponent == "fixture 2.KeyStepPro")
        #expect(outcome.note?.contains("fixture 2.KeyStepPro") == true)
    }

    @Test func afailureCarriesTheMessageWithoutTheCommandPrefix() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appending(path: "absent.mid")
        let destination = Destination(directory: directory, note: nil)

        let outcome = await Conversion.run(.toProject(missing), named: "absent", into: destination)

        #expect(outcome.failed)
        #expect(outcome.written == nil)
        // The runner spells failures "<prog>: <message>" for a terminal; the window drops the prefix.
        #expect(!outcome.headline.hasPrefix("ksp-swift-cli"))
        #expect(!outcome.headline.isEmpty)
    }
}
