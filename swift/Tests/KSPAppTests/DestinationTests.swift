import Foundation
import Testing

@testable import KSPApp

/// MCC's Project Browser lists the *filename*, so these rules name the project on the device.
@Suite struct DestinationTests {
    @Test func aWritableTemplatesFolderIsUsedAsIs() throws {
        let templates = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: templates) }

        let destination = Destinations.forProjects(
            templates: templates, downloads: URL(filePath: "/nowhere"), isWritable: { _ in true })

        #expect(destination.directory == templates)
        #expect(destination.note == nil)
    }

    @Test func anUnwritableTemplatesFolderFallsBackToDownloads() {
        let downloads = URL(filePath: "/Users/someone/Downloads")

        let destination = Destinations.forProjects(
            templates: URL(filePath: "/Library/nope"), downloads: downloads,
            isWritable: { _ in false })

        #expect(destination.directory == downloads)
        #expect(destination.note?.contains("/Library/nope") == true)
    }

    @Test func anExportLandsBesideTheProjectItCameFrom() {
        let source = URL(filePath: "/tmp/songs/take 3.KeyStepPro")

        let destination = Destinations.forMIDI(source: source, chosen: nil)

        // By path: `deletingLastPathComponent` leaves a trailing slash that URL equality counts.
        #expect(destination.directory.path == "/tmp/songs")
        #expect(destination.note == nil)
    }

    @Test func achosenProjectFolderSkipsTheTemplatesLadder() {
        let chosen = URL(filePath: "/Users/someone/Desktop")
        var asked = false

        let destination = Destinations.forProjects(
            chosen: chosen, templates: URL(filePath: "/Library/nope"),
            downloads: URL(filePath: "/Users/someone/Downloads"),
            isWritable: { _ in
                asked = true
                return false
            })

        #expect(destination.directory == chosen)
        #expect(destination.note == nil)
        #expect(!asked, "a chosen folder is not second-guessed against Templates")
    }

    @Test func achosenMIDIFolderBeatsLandingBesideTheSource() {
        let chosen = URL(filePath: "/Users/someone/Music")

        let destination = Destinations.forMIDI(
            source: URL(filePath: "/tmp/songs/take 3.KeyStepPro"), chosen: chosen)

        #expect(destination.directory == chosen)
        #expect(destination.note == nil)
    }

}

@Suite struct MCCWarningTests {
    private let templates = URL(
        filePath: "/Library/Arturia/MIDI Control Center/Templates/KeyStepPro")

    @Test func thedefaultPlacementIsNotWarnedAbout() {
        #expect(Destinations.mccWarning(for: nil, templates: templates) == nil)
    }

    @Test(arguments: [
        "/Library/Arturia/MIDI Control Center/Templates/KeyStepPro",
        "/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/",
        "/Library/Arturia/MIDI Control Center/Templates/../Templates/KeyStepPro",
    ])
    func choosingTheTemplatesFolderItselfIsNotWarnedAbout(path: String) {
        #expect(Destinations.mccWarning(for: URL(filePath: path), templates: templates) == nil)
    }

    /// `/tmp` is a symlink to `/private/tmp`, so a folder can be Templates without being spelled so.
    @Test func afolderReachedThroughASymlinkIsStillTheTemplatesFolder() throws {
        let real = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: real) }
        let link = FileManager.default.temporaryDirectory
            .appending(path: "ksp-app-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link) }

        #expect(Destinations.mccWarning(for: link, templates: real) == nil)
    }

    @Test func anyOtherFolderSaysTheProjectBrowserWillNotListIt() throws {
        let warning = try #require(
            Destinations.mccWarning(
                for: URL(filePath: "/Users/someone/Desktop"), templates: templates))

        #expect(warning.contains("Project Browser"))
    }
}

@Suite struct NamingTests {
    @Test func theStemIsTheSourceFilenameWithoutItsExtension() {
        #expect(Naming.stem(of: URL(filePath: "/tmp/my song.mid")) == "my song")
    }

    @Test(
        arguments: [
            ("a/b", "a-b"),
            ("a:b", "a-b"),
            ("  padded  ", "padded"),
            (".hidden", "hidden"),
            ("", Naming.fallbackStem),
            ("   ", Naming.fallbackStem),
            ("...", Naming.fallbackStem),
        ])
    func sanitisingKeepsANameTheFilesystemAndFinderBothAccept(raw: String, expected: String) {
        #expect(Naming.sanitised(raw) == expected)
    }

    @Test func anUntakenNameIsLeftAlone() {
        let url = Naming.vacant(
            in: URL(filePath: "/tmp"), stem: "song", extension: "KeyStepPro", exists: { _ in false }
        )

        #expect(url.lastPathComponent == "song.KeyStepPro")
    }

    @Test func atakenNameClimbsUntilOneIsFree() {
        let taken: Set<String> = ["song.KeyStepPro", "song 2.KeyStepPro"]

        let url = Naming.vacant(
            in: URL(filePath: "/tmp"), stem: "song", extension: "KeyStepPro",
            exists: { taken.contains($0.lastPathComponent) })

        #expect(url.lastPathComponent == "song 3.KeyStepPro")
    }

    @Test func anUntakenFolderNameIsLeftAlone() {
        let url = Naming.vacantFolder(
            in: URL(filePath: "/tmp"), stem: "song", exists: { _ in false })

        #expect(url.lastPathComponent == "song")
        #expect(url.pathExtension.isEmpty)
    }

    @Test func aTakenFolderNameClimbsUntilOneIsFree() {
        let taken: Set<String> = ["song", "song 2"]

        let url = Naming.vacantFolder(
            in: URL(filePath: "/tmp"), stem: "song",
            exists: { taken.contains($0.lastPathComponent) })

        #expect(url.lastPathComponent == "song 3")
    }

    @Test func aFolderNameIsSanitisedLikeAFileName() {
        let url = Naming.vacantFolder(
            in: URL(filePath: "/tmp"), stem: "a/b:c", exists: { _ in false })

        #expect(url.lastPathComponent == Naming.sanitised("a/b:c"))
    }

}
