import Foundation
import KSPRun
import Testing

@testable import KSPApp

/// One ``Settings`` per direction, plus the two the app rather than a direction owns.
@Suite struct SettingsStoreTests {
    @Test func afreshStoreReadsTheDefaults() {
        withVolatileDefaults { defaults in
            let store = SettingsStore(defaults: defaults)

            for kind in Job.Kind.allCases { #expect(store.load(kind) == Settings()) }
            #expect(!store.loadVerbose())
        }
    }

    @Test func asettingSurvivesTheNextLaunch() {
        withVolatileDefaults { defaults in
            var settings = Settings()
            settings.repeatCount = 7
            settings.stepSkip = .three
            settings.ignoreSwing = true
            SettingsStore(defaults: defaults).save(settings, for: .toMIDI)

            #expect(SettingsStore(defaults: defaults).load(.toMIDI) == settings)
        }
    }

    @Test func thetwoDirectionsAreRememberedApart() {
        withVolatileDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            var export = Settings()
            export.repeatCount = 4
            export.drumChannel = 12
            var `import` = Settings()
            `import`.ignoreVelocity = true

            store.save(export, for: .toMIDI)
            store.save(`import`, for: .toProject)

            #expect(store.load(.toMIDI).repeatCount == 4)
            // The one key both blobs carry, which is the whole reason for two slots.
            #expect(store.load(.toMIDI).drumChannel == 12)
            #expect(store.load(.toProject).drumChannel == Settings().drumChannel)
            #expect(store.load(.toProject).ignoreVelocity)
        }
    }

    /// Unlike the drum track below, which a drop names, both of these are preferences.
    @Test(arguments: Settings.Drums.allCases)
    func thedrumDesignationAndItsChannelSurviveTheNextLaunch(drums: Settings.Drums) {
        withVolatileDefaults { defaults in
            var settings = Settings()
            settings.drums = drums
            settings.drumChannel = 3
            SettingsStore(defaults: defaults).save(settings, for: .toProject)

            let loaded = SettingsStore(defaults: defaults).load(.toProject)
            #expect(loaded.drums == drums)
            #expect(loaded.drumChannel == 3)
        }
    }

    @Test func ablobFromBeforeTheDrumChoiceReadsAsTheDefaults() {
        withVolatileDefaults { defaults in
            defaults.set(Data(#"{"ignoreSwing":true}"#.utf8), forKey: "settings.toProject")

            let loaded = SettingsStore(defaults: defaults).load(.toProject)

            #expect(loaded.ignoreSwing)
            #expect(loaded.drums == Settings().drums)
            #expect(loaded.drumChannel == Settings().drumChannel)
        }
    }

    /// What a drop chose is not a preference: it must not come back on the next file.
    @Test func adropsOwnSelectionIsNotRemembered() {
        withVolatileDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            var settings = Settings()
            settings.cells = [1: [1, 2]]
            settings.routeSpec = "1:2"
            settings.midiTracksSpec = "1,2"
            settings.drumTrack = 3

            store.save(settings, for: .toProject)

            #expect(store.load(.toProject) == Settings())
        }
    }

    /// A field added later costs the reader that one setting, not everything it had remembered.
    @Test func ablobMissingAkeyKeepsTheKeysItHas() throws {
        withVolatileDefaults { defaults in
            defaults.set(
                Data(#"{"repeatCount":9,"ignoreSwing":true}"#.utf8), forKey: "settings.toMIDI")

            let loaded = SettingsStore(defaults: defaults).load(.toMIDI)

            #expect(loaded.repeatCount == 9)
            #expect(loaded.ignoreSwing)
            #expect(loaded.stepSkip == .auto)
        }
    }

    /// Unlike every setting beside it. A launch that remembered a dry run would write nothing for
    /// every file after it, and say so nowhere but on the button.
    @Test func thedryRunDoesNotSurviveTheNextLaunch() {
        withVolatileDefaults { defaults in
            var settings = Settings()
            settings.dryRun = true
            settings.repeatCount = 7
            SettingsStore(defaults: defaults).save(settings, for: .toMIDI)

            let loaded = SettingsStore(defaults: defaults).load(.toMIDI)

            #expect(!loaded.dryRun)
            #expect(loaded.repeatCount == 7)
        }
    }

    /// A build that did store it left the key in someone's defaults, where it must stay inert.
    @Test func astoredDryRunFromAnEarlierBuildIsIgnored() {
        withVolatileDefaults { defaults in
            defaults.set(Data(#"{"dryRun":true,"repeatCount":9}"#.utf8), forKey: "settings.toMIDI")

            let loaded = SettingsStore(defaults: defaults).load(.toMIDI)

            #expect(!loaded.dryRun)
            #expect(loaded.repeatCount == 9)
        }
    }

    /// How long a finding list is drawn is the app's, not either direction's, so it is kept where
    /// the two cannot disagree. A build that did store it per direction left the key behind.
    @Test func theFindingListLengthIsOnePreferenceRatherThanTwo() {
        withVolatileDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            store.save(verbose: true)
            defaults.set(Data(#"{"verbose":true,"repeatCount":9}"#.utf8), forKey: "settings.toMIDI")

            #expect(SettingsStore(defaults: defaults).loadVerbose())
            #expect(!store.load(.toMIDI).verbose)
            #expect(store.load(.toMIDI).repeatCount == 9)
        }
    }
}

/// One face: every option reaches the conversion, and an untouched app is still the CLI on its
/// own defaults.
@MainActor
@Suite struct AppModelOptionsTests {
    private var midiFixture: URL { RepoData.projectFiles.appending(path: "m6-test-file.mid") }

    private var projectFixture: URL {
        RepoData.projectFiles.appending(path: "project_5.KeyStepPro")
    }

    private func model(writingInto directory: URL, over defaults: UserDefaults = volatileDefaults())
        -> AppModel
    {
        AppModel(
            store: FolderStore(defaults: defaults),
            settingsStore: SettingsStore(defaults: defaults),
            destination: { _, _ in Destination(directory: directory, note: nil) },
            reveal: { _ in }, chooseFolder: { _ in nil }, recents: volatileRecents())
    }

    /// ``AppModel/kind`` is what picks the direction's options, so each one is edited exactly
    /// while the slot it writes to is the one being shown.
    @Test func eachDirectionIsEditedApartFromTheOther() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)

        model.accept(midiFixture)
        #expect(model.kind == .toProject)
        model.settings.ignoreSwing = true

        model.accept(projectFixture)
        #expect(model.kind == .toMIDI)
        #expect(!model.settings.ignoreSwing)
        model.settings.repeatCount = 6

        model.accept(midiFixture)
        #expect(model.settings.ignoreSwing)
        #expect(model.settings.repeatCount == 1)

        // The export's options are reachable again, and kept what they were last given.
        model.accept(projectFixture)
        #expect(model.settings.repeatCount == 6)
    }

    /// With nothing staged the options belong to the direction last shown, so a drop the other way
    /// swaps the slot under them. They move with it rather than following the file.
    @Test func asettingMadeBeforeAdropBelongsToTheDirectionThatWasShowing() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.settings.ignoreSwing = true

        model.accept(projectFixture)
        #expect(!model.settings.ignoreSwing)

        model.accept(midiFixture)
        #expect(model.settings.ignoreSwing)
    }

    /// Whichever direction is showing reads the one preference, and neither slot swallows it.
    @Test func theFindingListLengthCrossesBothDirections() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)

        model.accept(midiFixture)
        model.verbose = true
        #expect(model.settings.verbose)

        model.accept(projectFixture)
        #expect(model.settings.verbose)
        model.settings.repeatCount = 6
        #expect(model.settings.verbose)
    }

    @Test func adroppedMIDIfilePlansTheImport() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)

        model.accept(midiFixture)

        #expect(model.segmentationKey != nil)
    }

    /// A project is laid out by the exporter rather than planned by the importer.
    @Test func aprojectPlansNoImport() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)

        model.accept(projectFixture)

        #expect(model.segmentationKey == nil)
        #expect(model.arrangementKey != nil)
    }

    @Test func theExportTicksReachTheConversion() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.accept(projectFixture)
        await model.summarise()

        model.toggle(track: 1, pattern: 1)

        let staged = try #require(model.staged)
        let settings = model.conversionSettings(staged)
        #expect(!settings.cells.isEmpty)
        #expect(settings.cells[1]?.contains(1) == false)
        // The ticks alone: nothing else has been touched.
        #expect(settings.repeatCount == Settings().repeatCount)
        #expect(!settings.verbose)
    }

    @Test func theImportTicksAndRoutesReachTheConversion() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.accept(midiFixture)
        await model.summarise()
        let ticked = try #require(model.staged).sourceSelection

        // Two of the four the read ticked: one dropped, one sent somewhere by hand.
        let numbers = (1...6).filter(ticked.isTicked)
        let dropped = try #require(numbers.first)
        let routed = try #require(numbers.last)
        model.toggle(sourceTrack: dropped)
        model.send(sourceTrack: routed, to: .track(4))

        let staged = try #require(model.staged)
        let settings = model.conversionSettings(staged)
        #expect(settings.midiTracksSpec != nil)
        #expect(settings.midiTracksSpec?.contains("\(dropped)") == false)
        #expect(settings.routeSpec == "\(routed):4")
        #expect(!settings.ignoreVelocity)
    }

    /// The milestone's last claim, which survives the sidebar going: an app nobody has touched
    /// writes the bytes the CLI writes on its own defaults.
    @Test(arguments: ["m6-test-file.mid", "project_5.KeyStepPro"])
    func anUntouchedConversionIsByteForByteTheCLIonItsDefaults(name: String) async throws {
        let appDirectory = try tempDirectory()
        let cliDirectory = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: appDirectory)
            try? FileManager.default.removeItem(at: cliDirectory)
        }
        let source = RepoData.projectFiles.appending(path: name)
        let model = model(writingInto: appDirectory)
        model.accept(source)

        // The read the staged view starts, so a seeded selection gets its chance to leak.
        await model.summarise()
        await model.convert()

        guard case .done(let outcome) = model.phase else {
            Issue.record("expected a finished conversion, got \(model.phase)")
            return
        }
        let written = try #require(outcome.written.first, "conversion failed: \(outcome.headline)")
        let target = cliDirectory.appending(path: written.lastPathComponent)
        let cli = run(source, into: target)
        #expect(cli.code == 0)
        #expect(try Data(contentsOf: written) == Data(contentsOf: target))
    }

    /// What the CLI does on nothing but its defaults, which is what an untouched app reproduces.
    private func run(_ source: URL, into target: URL) -> RunResult {
        source.pathExtension == "mid"
            ? ConvertRunner.run(
                ConvertRunner.Options(
                    paths: [source], output: target, configPath: drumMapConfigPath))
            : ExportRunner.run(
                ExportRunner.Options(path: source, output: target, configPath: drumMapConfigPath))
    }
}
