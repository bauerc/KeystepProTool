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

    @Test func ablobThatNoLongerReadsFallsBackToTheDefaults() {
        withVolatileDefaults { defaults in
            defaults.set(Data("not settings".utf8), forKey: "settings.toMIDI")

            #expect(SettingsStore(defaults: defaults).load(.toMIDI) == Settings())
        }
    }
}

/// Simple is the app as it shipped: it converts on the defaults and reaches nothing Advanced set.
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
        model.settings.dryRun = true
        model.settings.repeatCount = 6
        model.settings.splitPerPattern = true

        model.mode = .simple

        #expect(model.settings == Settings())
        model.accept(projectFixture)
        let staged = try #require(model.staged)
        #expect(model.conversionSettings(staged) == Settings())
        // The one setting that reaches the plan rather than the runner.
        #expect(!model.plan(for: staged.job).intoFolder)
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

    @Test func eachDirectionIsEditedApartFromTheOther() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.mode = .advanced

        model.accept(midiFixture)
        model.settings.ignoreSwing = true
        model.settings.dryRun = true

        model.accept(projectFixture)
        #expect(!model.settings.ignoreSwing)
        // Shared by nothing but these two slots, which is why there are two.
        #expect(!model.settings.dryRun)
        model.settings.repeatCount = 6

        model.accept(midiFixture)
        #expect(model.settings.ignoreSwing)
        #expect(model.settings.dryRun)
        #expect(model.settings.repeatCount == 1)
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

    @Test func simplePlansNoImport() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)

        model.accept(midiFixture)
        #expect(model.segmentationKey == nil)

        model.mode = .advanced
        #expect(model.segmentationKey != nil)
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
