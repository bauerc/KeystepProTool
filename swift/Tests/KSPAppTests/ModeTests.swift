import Foundation
import KSPRun
import Testing

@testable import KSPApp

/// Simple is the face the app first shipped with, so it is the one a fresh launch opens on.
@Suite struct ModeTests {
    @Test func afreshStoreOpensSimpleOnTheDefaults() {
        withVolatileDefaults { defaults in
            let store = SettingsStore(defaults: defaults)

            #expect(store.loadMode() == .simple)
            for kind in Job.Kind.allCases { #expect(store.load(kind) == Settings()) }
        }
    }

    @Test(arguments: Mode.allCases)
    func thechosenModeSurvivesTheNextLaunch(mode: Mode) {
        withVolatileDefaults { defaults in
            SettingsStore(defaults: defaults).save(mode)

            #expect(SettingsStore(defaults: defaults).loadMode() == mode)
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
            export.dryRun = true
            var `import` = Settings()
            `import`.ignoreVelocity = true

            store.save(export, for: .toMIDI)
            store.save(`import`, for: .toProject)

            #expect(store.load(.toMIDI).repeatCount == 4)
            #expect(store.load(.toMIDI).dryRun)
            // The one field the two share, which is the whole reason for two slots.
            #expect(!store.load(.toProject).dryRun)
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
            #expect(!loaded.dryRun)
        }
    }

    @Test func ablobThatNoLongerReadsFallsBackToTheDefaults() {
        withVolatileDefaults { defaults in
            defaults.set(Data("not settings".utf8), forKey: "settings.toMIDI")

            #expect(SettingsStore(defaults: defaults).load(.toMIDI) == Settings())
        }
    }
}

/// Simple converts on the defaults plus this drop's ticks, and reaches nothing else Advanced set.
@MainActor
@Suite struct AppModelModeTests {
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
            reveal: { _ in }, chooseFolder: { _ in nil })
    }

    @Test func afreshAppOpensSimple() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(model(writingInto: directory).mode == .simple)
    }

    @Test func thechosenFaceSurvivesTheNextLaunch() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        withVolatileDefaults { defaults in
            model(writingInto: directory, over: defaults).mode = .advanced

            #expect(model(writingInto: directory, over: defaults).mode == .advanced)
        }
    }

    @Test func simpleConvertsOnTheDefaultsWhateverAdvancedHolds() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.mode = .advanced
        model.settings.repeatCount = 6
        model.settings.verbose = true
        model.settings.splitPerPattern = true

        model.mode = .simple

        #expect(model.settings == Settings())
        model.accept(projectFixture)
        let staged = try #require(model.staged)
        // Nothing has been unticked, so the selections come to the defaults as well.
        #expect(model.conversionSettings(staged) == Settings())
        // The one setting that reaches the plan rather than the runner.
        #expect(!model.plan(for: staged.job).intoFolder)
    }

    /// The one option both faces show, so it is the one field that crosses between them.
    @Test func thedryRunIsTheOneSettingSimpleWritesThrough() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.mode = .advanced
        model.settings.repeatCount = 6

        model.mode = .simple
        model.settings.dryRun = true

        #expect(model.settings.dryRun)
        // Simple wrote the dry run without taking the defaults it read down with it.
        model.mode = .advanced
        #expect(model.settings.dryRun)
        #expect(model.settings.repeatCount == 6)
    }

    @Test func whatAdvancedHeldIsStillThereOnTheWayBack() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.mode = .advanced
        model.settings.repeatCount = 6

        model.mode = .simple
        model.mode = .advanced

        #expect(model.settings.repeatCount == 6)
    }

    /// ``AppModel/kind`` is also what picks the sidebar's one group, so each direction's controls
    /// are reachable exactly while the slot they write to is the one being edited.
    @Test func eachDirectionIsEditedApartFromTheOther() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.mode = .advanced

        model.accept(midiFixture)
        #expect(model.kind == .toProject)
        model.settings.ignoreSwing = true
        model.settings.dryRun = true

        model.accept(projectFixture)
        #expect(model.kind == .toMIDI)
        #expect(!model.settings.ignoreSwing)
        // Shared by nothing but these two slots, which is why there are two.
        #expect(!model.settings.dryRun)
        model.settings.repeatCount = 6

        model.accept(midiFixture)
        #expect(model.settings.ignoreSwing)
        #expect(model.settings.dryRun)
        #expect(model.settings.repeatCount == 1)

        // The export group is reachable again, and kept what it was last given.
        model.accept(projectFixture)
        #expect(model.settings.repeatCount == 6)
    }

    /// With nothing staged the panel is editing the direction it last showed, so a drop the other
    /// way swaps the slot under it. The ticks move with it rather than following the file.
    @Test func asettingMadeBeforeAdropBelongsToTheDirectionThePanelWasShowing() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.mode = .advanced
        model.settings.dryRun = true

        model.accept(projectFixture)
        #expect(!model.settings.dryRun)

        model.accept(midiFixture)
        #expect(model.settings.dryRun)
    }

    /// Both faces draw the segmentation grid and the limits, so both wait on the same plan.
    @Test(arguments: Mode.allCases)
    func eitherFacePlansTheImport(mode: Mode) throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.mode = mode

        model.accept(midiFixture)

        #expect(model.segmentationKey != nil)
    }

    /// A project is planned by the grid it draws, not by the importer.
    @Test func aprojectPlansNoImport() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)

        model.accept(projectFixture)

        #expect(model.segmentationKey == nil)
    }

    /// The point of the whole face: a tick drawn under Simple has to reach the conversion.
    @Test func simplefollowsTheExportTicks() async throws {
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
        // The ticks alone: no option Advanced holds came with them.
        #expect(settings.repeatCount == Settings().repeatCount)
        #expect(!settings.verbose)
    }

    @Test func simplefollowsTheImportTicksAndRoutes() async throws {
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

    @Test func switchingFaceDiscardsAdryRunPreview() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.mode = .advanced
        model.accept(projectFixture)
        model.settings.dryRun = true
        await model.convert()
        #expect(model.staged?.preview != nil)

        model.mode = .simple

        #expect(model.staged?.preview == nil)
    }

    /// The milestone's last claim: every option added since M13 leaves Simple's bytes alone.
    @Test(arguments: ["m6-test-file.mid", "project_5.KeyStepPro"])
    func asimpleConversionIsByteForByteTheCLIonItsDefaults(name: String) async throws {
        let appDirectory = try tempDirectory()
        let cliDirectory = try tempDirectory()
        defer {
            try? FileManager.default.removeItem(at: appDirectory)
            try? FileManager.default.removeItem(at: cliDirectory)
        }
        let source = RepoData.projectFiles.appending(path: name)
        let model = model(writingInto: appDirectory)
        model.accept(source)
        // Set against this very drop, so each direction's slot holds a lever that would show.
        model.mode = .advanced
        model.settings.repeatCount = 6
        model.settings.ignoreVelocity = true
        model.mode = .simple

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

    /// What the CLI does on nothing but its defaults, which is what Simple claims to reproduce.
    private func run(_ source: URL, into target: URL) -> RunResult {
        source.pathExtension == "mid"
            ? ConvertRunner.run(
                ConvertRunner.Options(
                    paths: [source], output: target, configPath: drumMapConfigPath))
            : ExportRunner.run(
                ExportRunner.Options(path: source, output: target, configPath: drumMapConfigPath))
    }
}
