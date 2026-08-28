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
        // The app converts the one file that was dropped; the CLI is what takes several.
        #expect(convert.paths == [source])
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
            paths: [source], output: output, configPath: mapped.configPath)

        #expect(mapped.track == defaults.track)
        #expect(mapped.pattern == defaults.pattern)
        #expect(mapped.drumTrack == defaults.drumTrack)
        #expect(mapped.drumMapSpec == defaults.drumMapSpec)
        #expect(mapped.carryTempo == defaults.carryTempo)
        #expect(mapped.fitSwing == defaults.fitSwing)
        #expect(mapped.fitTimeShift == defaults.fitTimeShift)
        #expect(mapped.template == defaults.template)
        #expect(mapped.midiTrack == defaults.midiTrack)
        #expect(mapped.midiTracksSpec == defaults.midiTracksSpec)
        #expect(mapped.routeSpec == defaults.routeSpec)
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

    @Test func thetickedSourceTracksReachTheImportAsTheOptionTheCLITakes() {
        var selection = SourceTrackSelection(
            syntheticSong(tracks: (1...6).map { sourceTrack($0) }))
        selection.toggle(1)

        let mapped = Settings().selecting(selection).convertOptions(source: source, output: output)

        #expect(mapped.midiTracksSpec == "2,3,4")
    }

    @Test func adestinationReachesTheRunnerAsTheRouteAndTheDrumTrack() {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...4).map { sourceTrack($0) }))
        selection.send(3, to: .track(2))
        selection.send(4, to: .drums)

        let mapped = Settings().selecting(selection).convertOptions(source: source, output: output)

        #expect(mapped.routeSpec == "3:2")
        #expect(mapped.drumTrack == 4)
    }

    /// A route and a selection are read together, so the app hands over both rather than choosing.
    @Test func aroutedTrackAndAnUntickedOneReachTheRunnerTogether() {
        var selection = SourceTrackSelection(syntheticSong(tracks: (1...5).map { sourceTrack($0) }))
        selection.send(2, to: .skip)
        selection.send(3, to: .track(4))

        let mapped = Settings().selecting(selection).convertOptions(source: source, output: output)

        #expect(mapped.midiTracksSpec == "1,3,4")
        #expect(mapped.routeSpec == "3:4")
    }

    /// The boundaries reach the runner as `--segment-bars`, which is the option the CLI already
    /// cuts on, rather than as a second mechanism of the app's own.
    @Test func draggedBoundariesReachTheRunnerAsTheSegmentation() {
        var boundaries = SegmentBoundaries()
        boundaries.seed(source: 2, bars: [5, 9])
        boundaries.move(source: 2, handle: 0, to: 4)

        let mapped = Settings().segmenting(boundaries)
            .convertOptions(source: source, output: output)

        #expect(mapped.segmentBarsSpec == "2:4,2:9")
    }

    @Test func anuntouchedSegmentationAsksForNothing() {
        let mapped = Settings().segmenting(SegmentBoundaries())
            .convertOptions(source: source, output: output)
        let defaults = ConvertRunner.Options(
            paths: [source], output: output, configPath: mapped.configPath)

        #expect(mapped.segmentBarsSpec == defaults.segmentBarsSpec)
        #expect(mapped.segmentBarsSpec == nil)
    }

    @Test func atickOnEverySourceTrackHoldingNotesAsksForNothing() {
        let mapped = Settings()
            .selecting(SourceTrackSelection(syntheticSong(tracks: [sourceTrack(1)])))
            .convertOptions(source: source, output: output)
        let defaults = ConvertRunner.Options(
            paths: [source], output: output, configPath: mapped.configPath)

        #expect(mapped.midiTracksSpec == defaults.midiTracksSpec)
        #expect(mapped.midiTracksSpec == nil)
    }

    @Test func thesourceTracksLeaveTheExportAlone() {
        var selection = SourceTrackSelection(
            syntheticSong(tracks: (1...6).map { sourceTrack($0) }))
        selection.toggle(1)

        let mapped = Settings().selecting(selection).exportOptions(source: output, output: source)
        let defaults = ExportRunner.Options(
            path: output, output: source, configPath: mapped.configPath)

        #expect(mapped.cells == defaults.cells)
    }

    @Test func aselectionLeavesTheImportRoutingAlone() {
        var selection = GridSelection(syntheticSummary())
        selection.toggle(track: 3)

        let mapped = Settings().selecting(selection).convertOptions(source: source, output: output)
        let defaults = ConvertRunner.Options(
            paths: [source], output: output, configPath: mapped.configPath)

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
            paths: [source], output: output, configPath: mapped.configPath)

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

    /// Nothing is ignored until it is asked for, so the app on defaults converts what the CLI on
    /// defaults converts.
    @Test func freshSettingsIgnoreNothing() {
        let settings = Settings()
        #expect(!settings.ignoreVelocity)
        #expect(!settings.ignoreSwing)
        #expect(!settings.ignoreTimeShift)

        let mapped = settings.convertOptions(source: source, output: output)
        let defaults = ConvertRunner.Options(
            paths: [source], output: output, configPath: mapped.configPath)

        #expect(mapped.flatVelocitySpec == defaults.flatVelocitySpec)
        #expect(mapped.fitSwing == defaults.fitSwing)
        #expect(mapped.fitTimeShift == defaults.fitTimeShift)
    }

    /// Pinned by parsing rather than by string equality, so the spelling cannot drift from the
    /// number it stands for.
    @Test func ignoringVelocityWritesTheFreshNoteValue() throws {
        var settings = Settings()
        settings.ignoreVelocity = true
        let mapped = settings.convertOptions(source: source, output: output)

        #expect(try parseFlatVelocity(mapped.flatVelocitySpec) == MIDIExport.defaultFlatVelocity)
        #expect(mapped.fitSwing)
        #expect(mapped.fitTimeShift)
    }

    /// On an import, swing is the groove fitted from the source, so ignoring it leaves the pattern
    /// straight rather than flattening a grid the project already stores.
    @Test func ignoringSwingStraightensEveryPatternAlone() {
        var settings = Settings()
        settings.ignoreSwing = true
        let mapped = settings.convertOptions(source: source, output: output)

        #expect(!mapped.fitSwing)
        #expect(mapped.fitTimeShift)
        #expect(mapped.flatVelocitySpec == nil)
    }

    @Test func ignoringTimeShiftQuantisesHardAlone() {
        var settings = Settings()
        settings.ignoreTimeShift = true
        let mapped = settings.convertOptions(source: source, output: output)

        #expect(!mapped.fitTimeShift)
        #expect(mapped.fitSwing)
        #expect(mapped.flatVelocitySpec == nil)
    }

    /// The inverse of ``replacingOnAnExportLeavesTheImportAlone``: the export's three mean something
    /// else, so the import's must not reach `ExportRunner` at all.
    @Test func ignoringOnAnImportLeavesTheExportAlone() {
        let mapped = Settings(ignoreVelocity: true, ignoreSwing: true, ignoreTimeShift: true)
            .exportOptions(source: output, output: source)
        let defaults = ExportRunner.Options(
            path: output, output: source, configPath: mapped.configPath)

        #expect(mapped.flatVelocity == defaults.flatVelocity)
        #expect(mapped.applySwing == defaults.applySwing)
        #expect(mapped.applyTimeShift == defaults.applyTimeShift)
    }

    @Test func ignoringNothingSaysNothing() {
        #expect(Settings().ignoredNote == nil)
    }

    /// Each choice names the value it substitutes rather than only saying it is off.
    @Test func eachIgnoredChoiceNamesItsSubstitute() {
        var velocity = Settings()
        velocity.ignoreVelocity = true
        #expect(
            velocity.ignoredNote == "Ignoring: velocity, writing \(MIDIExport.defaultFlatVelocity)")

        var swing = Settings()
        swing.ignoreSwing = true
        #expect(swing.ignoredNote == "Ignoring: swing, leaving every pattern straight")

        var timeShift = Settings()
        timeShift.ignoreTimeShift = true
        #expect(timeShift.ignoredNote == "Ignoring: time shift, quantising hard")
    }

    @Test func allThreeIgnoresReadAsOneLine() {
        let settings = Settings(ignoreVelocity: true, ignoreSwing: true, ignoreTimeShift: true)
        #expect(
            settings.ignoredNote
                == "Ignoring: velocity, writing \(MIDIExport.defaultFlatVelocity) · swing, "
                + "leaving every pattern straight · time shift, quantising hard")
    }

    /// The two panels answer for opposite directions, so a reader must never be able to mistake one
    /// line for the other: not the verb it opens with, and not the substitute it names.
    @Test func theTwoPanelsShareNoWording() {
        let settings = Settings(
            replaceVelocity: true, replaceSwing: true, replaceTimeShift: true,
            ignoreVelocity: true, ignoreSwing: true, ignoreTimeShift: true)
        let exported = settings.replacementNote
        let imported = settings.ignoredNote

        #expect(exported != imported)
        #expect(imported?.hasPrefix("Replacing:") == false)
        #expect(exported?.hasPrefix("Ignoring:") == false)
        #expect(imported?.contains("with a flat grid") == false)
        #expect(exported?.contains("leaving every pattern straight") == false)
    }
}
