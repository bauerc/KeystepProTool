import Foundation
import Testing
import UniformTypeIdentifiers

@testable import KSPApp

@MainActor
@Suite struct OpeningTests {
    /// A class so the model and the test share the one instance.
    private final class PanelLog {
        var openings = 0
    }

    private func model(
        picking picked: URL?, log: PanelLog = PanelLog(),
        recents: RecentFiles = volatileRecents()
    ) -> AppModel {
        AppModel(
            store: FolderStore(defaults: volatileDefaults()),
            settingsStore: advancedSettings(),
            destination: { _, _ in
                Destination(directory: FileManager.default.temporaryDirectory, note: nil)
            },
            reveal: { _ in }, chooseFolder: { _ in nil },
            chooseFile: {
                log.openings += 1
                return picked
            }, recents: recents)
    }

    private var midiFixture: URL { RepoData.projectFiles.appending(path: "m6-test-file.mid") }

    private var projectFixture: URL {
        RepoData.projectFiles.appending(path: "project_5.KeyStepPro")
    }

    /// The panel offering a file the app then refuses is the one drift that matters here.
    @Test func everyExtensionThePanelOffersIsOneTheAppCanConvert() {
        for name in Conversion.openableExtensions {
            #expect(
                Conversion.job(for: URL(filePath: "song.\(name)")) != nil,
                "the panel offers .\(name), which no direction accepts")
        }
    }

    @Test func theOpenPanelFiltersToMIDIandProjects() throws {
        let types = Conversion.openableTypes

        #expect(types.contains(.midi))
        #expect(
            types.contains { $0.preferredFilenameExtension?.lowercased() == "keysteppro" },
            "the project extension is missing from \(types)")
        #expect(types.count == Set(types).count, "a type is offered twice")
    }

    @Test func openStagesThePickedFileRatherThanConvertingIt() throws {
        let model = model(picking: midiFixture)

        model.open()

        let staged = try #require(model.staged, "the picked file should have been staged")
        #expect(staged.job == .toProject(midiFixture))
        #expect(model.name == "m6-test-file")
    }

    @Test func acancelledPanelStagesNothing() {
        let model = model(picking: nil)

        model.open()

        #expect(model.staged == nil)
        #expect(model.recentFiles.isEmpty)
    }

    /// A file picked mid-run would be staged and then thrown away by the run's own answer, so the
    /// menu item is disabled and the panel never opens.
    @Test func openIsShutWhileArunIsInFlight() {
        let log = PanelLog()
        let model = model(picking: midiFixture, log: log)
        model.phase = .working("m6-test-file.mid")

        #expect(!model.canAccept)
        model.open()

        #expect(log.openings == 0, "the panel should not have opened")
        #expect(model.staged == nil)
    }

    @Test func adroppedFileIsRememberedForOpenRecent() {
        let log = RecentFilesLog()
        let model = model(picking: nil, recents: log.store)

        model.accept(midiFixture)

        #expect(model.recentFiles == [midiFixture])
        #expect(log.urls == [midiFixture])
    }

    /// Recent to the app is what it could open. A file it has no direction for never was.
    @Test func afileTheAppCannotOpenIsNotRemembered() {
        let model = model(picking: nil)

        model.accept(RepoData.projectFiles.appending(path: "notes.txt"))

        #expect(model.recentFiles.isEmpty)
    }

    @Test func theFileOpenedLastIsTheFirstInTheMenu() {
        let model = model(picking: nil)

        model.accept(midiFixture)
        model.accept(projectFixture)
        model.accept(midiFixture)

        #expect(model.recentFiles == [midiFixture, projectFixture])
    }

    @Test func clearMenuEmptiesTheList() {
        let log = RecentFilesLog()
        let model = model(picking: nil, recents: log.store)
        model.accept(midiFixture)

        model.clearRecentFiles()

        #expect(model.recentFiles.isEmpty)
        #expect(log.clearances == 1)
    }

    /// The menu is drawn from the model, so what a previous launch left has to be in it already.
    @Test func themenuHoldsWhatAnEarlierLaunchOpened() {
        let log = RecentFilesLog()
        log.store.note(projectFixture)

        let model = model(picking: nil, recents: log.store)

        #expect(model.recentFiles == [projectFixture])
    }
}
