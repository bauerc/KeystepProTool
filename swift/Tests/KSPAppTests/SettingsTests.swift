import Foundation
import KSPRun
import Testing

@testable import KSPApp

/// The mapping from what the window offers onto what the runners take: that a control reaches the
/// runner, and that the controls not yet built leave the runner's own defaults alone.
@Suite struct SettingsTests {
    private let source = URL(filePath: "/tmp/song.mid")
    private let output = URL(filePath: "/tmp/song.KeyStepPro")

    @Test func aFreshSettingsWritesForReal() {
        let settings = Settings()
        #expect(!settings.dryRun)
        #expect(!settings.verbose)
    }

    @Test func bothDirectionsCarryThePathsAndTheDrumMapConfig() {
        let settings = Settings()

        let convert = settings.convertOptions(source: source, output: output)
        #expect(convert.path == source)
        #expect(convert.output == output)
        #expect(convert.configPath == drumMapConfigPath)

        let export = settings.exportOptions(source: output, output: source)
        #expect(export.path == output)
        #expect(export.output == source)
        #expect(export.configPath == drumMapConfigPath)
    }

    @Test(arguments: [false, true])
    func dryRunReachesBothRunners(on: Bool) {
        let settings = Settings(dryRun: on, verbose: false)
        #expect(settings.convertOptions(source: source, output: output).dryRun == on)
        #expect(settings.exportOptions(source: output, output: source).dryRun == on)
    }

    /// "Show every finding" has to reach the runner, not just the renderer.
    @Test(arguments: [false, true])
    func showingEveryFindingReachesBothRunners(on: Bool) {
        let settings = Settings(dryRun: false, verbose: on)
        #expect(settings.convertOptions(source: source, output: output).verbose == on)
        #expect(settings.exportOptions(source: output, output: source).verbose == on)
    }

    /// The window never waives the runner's overwrite guard.
    @Test func neitherDirectionForcesAnOverwrite() {
        let settings = Settings(dryRun: false, verbose: true)
        #expect(!settings.convertOptions(source: source, output: output).force)
        #expect(!settings.exportOptions(source: output, output: source).force)
    }

    /// The app reads the runner's summary out of `stdout`, so it must not silence it.
    @Test func neitherDirectionSilencesTheSummary() {
        let settings = Settings()
        #expect(!settings.convertOptions(source: source, output: output).quiet)
        #expect(!settings.exportOptions(source: output, output: source).quiet)
    }

    /// Everything the window does not offer yet keeps the runner's own default.
    @Test func anImportLeavesEveryUnofferedOptionAtItsDefault() {
        let mapped = Settings(dryRun: true, verbose: true)
            .convertOptions(source: source, output: output)
        let defaults = ConvertRunner.Options(
            path: source, output: output, configPath: mapped.configPath)

        #expect(mapped.track == defaults.track)
        #expect(mapped.pattern == defaults.pattern)
        #expect(mapped.drumTrack == defaults.drumTrack)
        #expect(mapped.drumMapSpec == defaults.drumMapSpec)
        #expect(mapped.carryTempo == defaults.carryTempo)
        #expect(mapped.fitSwing == defaults.fitSwing)
        #expect(mapped.fitTimeShift == defaults.fitTimeShift)
        #expect(mapped.template == defaults.template)
        #expect(mapped.midiTrack == defaults.midiTrack)
        #expect(mapped.stepsPerBeat == defaults.stepsPerBeat)
    }

    @Test func anExportLeavesEveryUnofferedOptionAtItsDefault() {
        let mapped = Settings(dryRun: true, verbose: true)
            .exportOptions(source: output, output: source)
        let defaults = ExportRunner.Options(
            path: output, output: source, configPath: mapped.configPath)

        #expect(mapped.split == defaults.split)
        #expect(mapped.tracks == defaults.tracks)
        #expect(mapped.patterns == defaults.patterns)
        #expect(mapped.passes == defaults.passes)
        #expect(mapped.ticksPerBeat == defaults.ticksPerBeat)
        #expect(mapped.drumMapSpec == defaults.drumMapSpec)
        #expect(mapped.drumChannel == defaults.drumChannel)
        #expect(mapped.defaultGate == defaults.defaultGate)
        #expect(mapped.includeStale == defaults.includeStale)
        #expect(mapped.includeDisabled == defaults.includeDisabled)
        #expect(mapped.applySwing == defaults.applySwing)
        #expect(mapped.applyTimeShift == defaults.applyTimeShift)
    }
}
