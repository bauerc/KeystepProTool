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

    @Test func anExportLandsBesideTheProjectItCameFrom() {
        let source = URL(filePath: "/tmp/songs/take 3.KeyStepPro")

        let destination = Destinations.beside(source)

        // By path: `deletingLastPathComponent` leaves a trailing slash, which URL equality counts
        // and `appending(path:)` does not.
        #expect(destination.directory.path == "/tmp/songs")
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
