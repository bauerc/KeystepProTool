import Foundation
import Testing

@testable import KSPApp

/// Where a converted file lands and what it is called.
///
/// MCC's Project Browser lists the *filename*, so these rules decide the name a project carries on
/// the device -- which makes them worth pinning even though no format code is involved.
@Suite struct DestinationTests {
    @Test func aWritableTemplatesFolderIsUsedAsIs() throws {
        let templates = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: templates) }

        let destination = Destinations.forProjects(
            templates: templates, downloads: URL(filePath: "/nowhere"), isWritable: { _ in true })

        #expect(destination.directory == templates)
        #expect(destination.note == nil)
    }

    /// Without MIDI Control Center installed there is no Templates folder, and the conversion
    /// still has to produce a file the user can find.
    @Test func anUnwritableTemplatesFolderFallsBackToDownloads() {
        let downloads = URL(filePath: "/Users/someone/Downloads")

        let destination = Destinations.forProjects(
            templates: URL(filePath: "/Library/nope"), downloads: downloads,
            isWritable: { _ in false })

        #expect(destination.directory == downloads)
        // The message has to name the folder, or the file is findable and still useless.
        #expect(destination.note?.contains("/Library/nope") == true)
    }

    /// Choosing nothing has to reproduce the shipped behaviour exactly.
    @Test func anExportLandsBesideTheProjectItCameFrom() {
        let source = URL(filePath: "/tmp/songs/take 3.KeyStepPro")

        let destination = Destinations.forMIDI(source: source, chosen: nil)

        // By path: `deletingLastPathComponent` leaves a trailing slash, which URL equality counts
        // and `appending(path:)` does not.
        #expect(destination.directory.path == "/tmp/songs")
        #expect(destination.note == nil)
    }

    /// A chosen folder is obeyed as it stands. The Templates ladder above is not consulted at all,
    /// so an unwritable Templates folder cannot divert a project the user has placed by hand.
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

/// The one thing the user gives up by choosing a project folder: MCC's Project Browser lists only
/// its own Templates folder, so it will not show the file. Said when the folder is chosen.
@Suite struct MCCWarningTests {
    private let templates = URL(
        filePath: "/Library/Arturia/MIDI Control Center/Templates/KeyStepPro")

    @Test func thedefaultPlacementIsNotWarnedAbout() {
        #expect(Destinations.mccWarning(for: nil, templates: templates) == nil)
    }

    /// Choosing the Templates folder by hand is the default by another route, not a mistake.
    @Test(arguments: [
        "/Library/Arturia/MIDI Control Center/Templates/KeyStepPro",
        "/Library/Arturia/MIDI Control Center/Templates/KeyStepPro/",
        "/Library/Arturia/MIDI Control Center/Templates/../Templates/KeyStepPro",
    ])
    func choosingTheTemplatesFolderItselfIsNotWarnedAbout(path: String) {
        #expect(Destinations.mccWarning(for: URL(filePath: path), templates: templates) == nil)
    }

    /// `/tmp` is a symlink to `/private/tmp` on macOS, so a folder can be the Templates folder
    /// without being spelled like it. Warning about the folder the user actually picked would be
    /// wrong twice over -- it is the default, and MCC will list the file.
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

    /// The app never overwrites: MCC's folder holds the user's own projects under freely chosen
    /// names, so a clash is as likely to be someone else's work as a re-run of this one.
    @Test func atakenNameClimbsUntilOneIsFree() {
        let taken: Set<String> = ["song.KeyStepPro", "song 2.KeyStepPro"]

        let url = Naming.vacant(
            in: URL(filePath: "/tmp"), stem: "song", extension: "KeyStepPro",
            exists: { taken.contains($0.lastPathComponent) })

        #expect(url.lastPathComponent == "song 3.KeyStepPro")
    }

}
