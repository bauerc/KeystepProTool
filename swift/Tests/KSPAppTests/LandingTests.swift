import Foundation
import Testing

@testable import KSPApp

private func plan(
    _ job: Job, named stem: String, into directory: String, splitting: Bool = false
) -> Conversion.Plan {
    Conversion.plan(
        job, named: stem,
        into: Destination(directory: URL(filePath: directory), note: nil),
        splitting: splitting)
}

@Suite struct LandingTests {
    @Test func theNameIsSaidApartFromTheFolderItLandsIn() {
        let landing = Landing(
            plan(.toProject(URL(filePath: "/tmp/take 3.mid")), named: "take 3", into: "/tmp/out"))

        #expect(landing.folder == "/tmp/out")
        #expect(landing.name == "take 3.KeyStepPro")
        #expect(landing.path == "/tmp/out/take 3.KeyStepPro")
    }

    /// The bar has one line for a path that can be twelve components long.
    @Test func aFolderUnderHomeIsTilded() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let landing = Landing(
            plan(
                .toMIDI(URL(filePath: "/tmp/song.KeyStepPro")), named: "song",
                into: "\(home)/Music"))

        #expect(landing.folder == "~/Music")
        #expect(landing.name == "song.mid")
    }

    @Test func aSplitRunNamesTheFolderItFills() {
        let landing = Landing(
            plan(
                .toMIDI(URL(filePath: "/tmp/song.KeyStepPro")), named: "song", into: "/tmp/out",
                splitting: true))

        #expect(landing.intoFolder)
        #expect(landing.name == "song")
        #expect(landing.spoken == "Writes into /tmp/out/song")
    }

    /// The folder truncates on screen, so the whole path has to reach a reader some other way.
    @Test func whatIsSpokenCarriesThePathTheBarTruncates() {
        let landing = Landing(
            plan(.toProject(URL(filePath: "/tmp/take 3.mid")), named: "take 3", into: "/tmp/out"))

        #expect(landing.spoken == "Writes to /tmp/out/take 3.KeyStepPro")
    }

    @Test func choosingFromTheBarEditsTheFolderTheJobWritesInto() {
        #expect(Job.toProject(URL(filePath: "/tmp/a.mid")).folderKind == .project)
        #expect(Job.toMIDI(URL(filePath: "/tmp/a.KeyStepPro")).folderKind == .midi)
    }
}
