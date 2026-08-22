import Foundation
import Testing

@testable import KSPApp

/// `nil` is not "unset": it *is* the default placement the app shipped with.
@Suite struct FoldersTests {
    private let desktop = URL(filePath: "/Users/someone/Desktop")
    private let music = URL(filePath: "/Users/someone/Music")

    @Test func nothingChosenIsTheDefaultForBoth() {
        let folders = Folders()

        #expect(folders.project == nil)
        #expect(folders.midi == nil)
    }

    @Test func afreshStoreRemembersNothing() {
        withVolatileDefaults { defaults in
            #expect(FolderStore(defaults: defaults).load { _ in true } == Folders())
        }
    }

    @Test func achosenFolderSurvivesTheNextLaunch() {
        withVolatileDefaults { defaults in
            FolderStore(defaults: defaults).save(Folders(project: desktop, midi: nil))

            // A second store over the same domain is what the next launch does.
            let loaded = FolderStore(defaults: defaults).load { _ in true }

            #expect(loaded.project == desktop)
            #expect(loaded.midi == nil)
        }
    }

    @Test func thetwoKindsAreSetIndependently() {
        withVolatileDefaults { defaults in
            let store = FolderStore(defaults: defaults)
            store.save(Folders(project: desktop, midi: music))

            let loaded = store.load { _ in true }

            #expect(loaded.project == desktop)
            #expect(loaded.midi == music)
        }
    }

    @Test func returningOneKindToItsDefaultLeavesTheOtherAlone() {
        withVolatileDefaults { defaults in
            let store = FolderStore(defaults: defaults)
            store.save(Folders(project: desktop, midi: music))

            store.save(Folders(project: nil, midi: music))

            let loaded = store.load { _ in true }
            #expect(loaded.project == nil)
            #expect(loaded.midi == music)
        }
    }

    /// A folder can be deleted or unmounted between launches, and reverting beats failing.
    @Test func afolderThatIsNoLongerThereRevertsToTheDefault() {
        withVolatileDefaults { defaults in
            let store = FolderStore(defaults: defaults)
            store.save(Folders(project: desktop, midi: music))

            let loaded = store.load { $0 != desktop }

            #expect(loaded.project == nil)
            #expect(loaded.midi == music)
        }
    }

    @Test func thesubscriptReachesBothKinds() {
        var folders = Folders()

        folders[.project] = desktop
        folders[.midi] = music

        #expect(folders[.project] == desktop)
        #expect(folders[.midi] == music)
        folders[.midi] = nil
        #expect(folders == Folders(project: desktop, midi: nil))
    }

    @Test func arowDescribesTheDefaultUntilAFolderIsChosen() {
        var folders = Folders()

        #expect(folders.description(of: .project) == FolderKind.project.defaultDescription)
        #expect(folders.description(of: .midi) == FolderKind.midi.defaultDescription)

        // Abbreviated against this account's own home, which is what the sidebar has to fit.
        folders.project = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop")
        #expect(folders.description(of: .project) == "~/Desktop")

        folders.midi = URL(filePath: "/Volumes/Stick/Bounces")
        #expect(folders.description(of: .midi) == "/Volumes/Stick/Bounces")
    }
}
