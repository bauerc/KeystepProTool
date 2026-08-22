import Foundation
import KSPKit
import KSPMIDI
import KSPRun
import Testing

@testable import KSPApp

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

    @Test(arguments: [false, true])
    func showingEveryFindingReachesBothRunners(on: Bool) {
        let settings = Settings(dryRun: false, verbose: on)
        #expect(settings.convertOptions(source: source, output: output).verbose == on)
        #expect(settings.exportOptions(source: output, output: source).verbose == on)
    }

    /// Only the export splits, so `ConvertRunner` has no such option to carry it to.
    @Test(arguments: [false, true])
    func splittingPerPatternReachesTheExport(on: Bool) {
        let settings = Settings(splitPerPattern: on)
        #expect(settings.exportOptions(source: output, output: source).split == on)
    }

    @Test func afreshSettingsWritesOneFile() {
        #expect(!Settings().splitPerPattern)
        #expect(!Settings().exportOptions(source: output, output: source).split)
    }

    @Test func neitherDirectionForcesAnOverwrite() {
        let settings = Settings(dryRun: false, verbose: true)
        #expect(!settings.convertOptions(source: source, output: output).force)
        #expect(!settings.exportOptions(source: output, output: source).force)
    }

    @Test func neitherDirectionSilencesTheSummary() {
        let settings = Settings()
        #expect(!settings.convertOptions(source: source, output: output).quiet)
        #expect(!settings.exportOptions(source: output, output: source).quiet)
    }

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
        #expect(mapped.midiTracks == defaults.midiTracks)
        #expect(mapped.stepsPerBeat == defaults.stepsPerBeat)
    }

    @Test func anExportLeavesEveryUnofferedOptionAtItsDefault() {
        let mapped = Settings(dryRun: true, verbose: true)
            .exportOptions(source: output, output: source)
        let defaults = ExportRunner.Options(
            path: output, output: source, configPath: mapped.configPath)

        #expect(mapped.tracks == defaults.tracks)
        #expect(mapped.patterns == defaults.patterns)
        #expect(mapped.ticksPerBeat == defaults.ticksPerBeat)
        #expect(mapped.drumMapSpec == defaults.drumMapSpec)
        #expect(mapped.drumChannel == defaults.drumChannel)
        #expect(mapped.defaultGate == defaults.defaultGate)
        #expect(mapped.includeStale == defaults.includeStale)
        #expect(mapped.includeDisabled == defaults.includeDisabled)
    }

    @Test func freshSettingsLeaveTheStepSkipCycleOnAuto() {
        let settings = Settings()
        #expect(settings.stepSkip == .auto)
        #expect(settings.exportOptions(source: output, output: source).passes == nil)
    }

    @Test(arguments: Settings.StepSkip.allCases)
    func everyStepSkipChoiceReachesTheExport(choice: Settings.StepSkip) {
        var settings = Settings()
        settings.stepSkip = choice
        #expect(settings.exportOptions(source: output, output: source).passes == choice.passes)
    }

    /// The cap is the device's four 16/32/48/64 sequences, not a number picked for the menu.
    @Test func theStepSkipChoicesAreTheDevicesOwnSequences() {
        #expect(
            Settings.StepSkip.allCases.compactMap(\.passes) == Array(1...Constants.skipCyclePasses))
        #expect(Settings.StepSkip.allCases.filter { $0.passes == nil } == [.auto])
    }

    @Test func freshSettingsLayTheExportDownOnce() {
        let settings = Settings()
        #expect(settings.repeatCount == 1)
        #expect(settings.exportOptions(source: output, output: source).repeatCount == 1)
    }

    @Test(arguments: Settings.repeatRange)
    func everyRepeatCountReachesTheExport(count: Int) {
        var settings = Settings()
        settings.repeatCount = count
        #expect(settings.exportOptions(source: output, output: source).repeatCount == count)
    }

    @Test func theStepperCannotOfferMoreThanTheExportAccepts() {
        #expect(Settings.repeatRange == 1...MIDIExport.maxRepeat)
    }

    @Test func thegridsTicksReachTheExport() {
        var selection = GridSelection(syntheticSummary())
        selection.toggle(track: 3)
        selection.toggle(track: 1, pattern: 5)

        let mapped = Settings().selecting(selection)
            .exportOptions(source: output, output: source)

        let every = Set(1...16)
        #expect(mapped.cells == [1: every.subtracting([5]), 2: every, 4: every])
    }

    @Test func afullyTickedGridAsksForNothing() {
        let mapped = Settings().selecting(GridSelection(syntheticSummary()))
            .exportOptions(source: output, output: source)
        let defaults = ExportRunner.Options(
            path: output, output: source, configPath: mapped.configPath)

        #expect(mapped.cells == defaults.cells)
        #expect(mapped.cells.isEmpty)
    }

    @Test func aselectionLeavesTheImportRoutingAlone() {
        var selection = GridSelection(syntheticSummary())
        selection.toggle(track: 3)

        let mapped = Settings().selecting(selection).convertOptions(source: source, output: output)
        let defaults = ConvertRunner.Options(
            path: source, output: output, configPath: mapped.configPath)

        #expect(mapped.track == defaults.track)
        #expect(mapped.pattern == defaults.pattern)
    }

    @Test func freshSettingsReplaceNothing() {
        let settings = Settings()
        #expect(!settings.replaceVelocity)
        #expect(!settings.replaceSwing)
        #expect(!settings.replaceTimeShift)

        let mapped = settings.exportOptions(source: output, output: source)
        let defaults = ExportRunner.Options(
            path: output, output: source, configPath: mapped.configPath)

        #expect(mapped.flatVelocity == defaults.flatVelocity)
        #expect(mapped.applySwing == defaults.applySwing)
        #expect(mapped.applyTimeShift == defaults.applyTimeShift)
    }

    @Test func replacingVelocityRendersAtTheFreshNoteValue() {
        var settings = Settings()
        settings.replaceVelocity = true
        let mapped = settings.exportOptions(source: output, output: source)

        #expect(mapped.flatVelocity == MIDIExport.defaultFlatVelocity)
        #expect(mapped.applySwing)
        #expect(mapped.applyTimeShift)
    }

    @Test func replacingSwingFlattensTheGridAlone() {
        var settings = Settings()
        settings.replaceSwing = true
        let mapped = settings.exportOptions(source: output, output: source)

        #expect(!mapped.applySwing)
        #expect(mapped.applyTimeShift)
        #expect(mapped.flatVelocity == nil)
    }

    @Test func replacingTimeShiftFlattensTheGridAlone() {
        var settings = Settings()
        settings.replaceTimeShift = true
        let mapped = settings.exportOptions(source: output, output: source)

        #expect(!mapped.applyTimeShift)
        #expect(mapped.applySwing)
        #expect(mapped.flatVelocity == nil)
    }

    /// On an import swing means fitting the source's groove, so these must not reach it at all.
    @Test func replacingOnAnExportLeavesTheImportAlone() {
        let mapped = Settings(replaceVelocity: true, replaceSwing: true, replaceTimeShift: true)
            .convertOptions(source: source, output: output)
        let defaults = ConvertRunner.Options(
            path: source, output: output, configPath: mapped.configPath)

        #expect(mapped.fitSwing == defaults.fitSwing)
        #expect(mapped.fitTimeShift == defaults.fitTimeShift)
    }

    @Test func replacingNothingSaysNothing() {
        #expect(Settings().replacementNote == nil)
    }

    @Test func eachReplacementNamesItsSubstitute() {
        var velocity = Settings()
        velocity.replaceVelocity = true
        #expect(
            velocity.replacementNote == "Replacing: velocity with \(MIDIExport.defaultFlatVelocity)"
        )

        var swing = Settings()
        swing.replaceSwing = true
        #expect(swing.replacementNote == "Replacing: swing with a flat grid")

        var timeShift = Settings()
        timeShift.replaceTimeShift = true
        #expect(timeShift.replacementNote == "Replacing: time shift with a flat grid")
    }

    @Test func allThreeReplacementsReadAsOneLine() {
        let settings = Settings(replaceVelocity: true, replaceSwing: true, replaceTimeShift: true)
        #expect(
            settings.replacementNote
                == "Replacing: velocity with \(MIDIExport.defaultFlatVelocity) · swing with a "
                + "flat grid · time shift with a flat grid")
    }
}
