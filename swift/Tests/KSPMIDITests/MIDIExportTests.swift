import Foundation
import KSPKit
import SwiftMIDIFile
import Testing

@testable import KSPMIDI

/// The 480/4 default: 1/16 steps at 480 ticks per beat.
private let ticksPerStep = 120

private func onePass() throws -> ExportOptions { try ExportOptions(passes: 1) }

private func flat() throws -> ExportOptions { try ExportOptions(applyTimeShift: false) }

/// The tenth note sits at step 13: note index and step index are different spaces.
private let project5Steps = [0, 1, 2, 3, 4, 5, 6, 7, 8, 12]

/// Tier 8's unit is 1/400 of a beat, so the +1..+4/-1..-4 ramp is 1, 2, 4, 5 ticks at 480.
private let project5RampTicks = [1, 2, 4, 5, -1, -2, -4, -5, 0, 2]

private let rampedStarts = zip(project5Steps, project5RampTicks).map { $0 * ticksPerStep + $1 }

private func project5() throws -> Project { try Samples.project("project_5") }
private func project9() throws -> Project { try Samples.project("project_9") }
private func initialProject() throws -> Project { try Samples.project("initial_project") }

private func exported5() throws -> ExportResult {
    try MIDIExport.exportProject(project5(), options: onePass())
}

private func exported5Flat() throws -> ExportResult {
    try MIDIExport.exportProject(
        project5(), options: ExportOptions(applyTimeShift: false, passes: 1))
}

@Suite struct MIDIExportTests {
    @Test func tempoAndResolutionComeFromTheProject() throws {
        let midi = try exported5().midi
        let conductor = midi.tracks[0]
        var tempo: UInt32?
        for event in conductor.events {
            if case .tempo(let any) = event.event { tempo = any.microsecondsPerQuarter }
        }
        #expect(tempo == 500_000)  // 120 BPM
        #expect(midi.timebase.ticksPerQuarterNote == 480)
        #expect(midi.format == .multipleTracksSynchronous)
    }

    @Test func eachTrackAndParameterSetBecomesItsOwnMIDITrack() throws {
        #expect(try exported5().trackNames == ["Track 1 (drum)", "Track 3"])
    }

    @Test func melodicNotesMatchTheDocumentedDescription() throws {
        let notes = try played(exported5().midi, "Track 3")

        #expect(notes.map(\.note) == Array(repeating: 48, count: 4) + [49, 49, 49, 49, 50, 50])
        #expect(notes.map(\.velocity) == [60, 70, 90, 100, 60, 70, 90, 100, 60, 120])
        #expect(notes.map(\.start) == rampedStarts)
        #expect(Set(notes.map(\.channel)) == [2])  // Track 3 -> MIDI channel 3
    }

    @Test func gateBecomesNoteLengthInSteps() throws {
        let notes = try played(exported5().midi, "Track 3")
        #expect(notes[8].start == 8 * ticksPerStep)
        #expect(notes[8].duration == 4 * ticksPerStep)
        #expect(notes[9].duration == Arithmetic.pyRound(3.5 * Double(ticksPerStep)))
    }

    @Test func aGateRunningIntoTheNextNoteIsShortenedNotOverlapped() throws {
        let result = try exported5Flat()
        let notes = try played(result.midi, "Track 3")
        let first = notes[0]
        let second = notes[1]
        #expect(first.note == 48)
        #expect(second.note == 48)
        #expect(first.duration == ticksPerStep)
        #expect(first.start + first.duration == second.start)
        #expect(result.warnings.contains { $0.contains("shortened") })
    }

    @Test func drumLanesMapOntoTheGeneralMIDIPercussionChannel() throws {
        let notes = try played(exported5Flat().midi, "Track 1 (drum)")

        #expect(notes.map(\.note) == [DrumMap.defaultChromaticLow, DrumMap.defaultChromaticLow])
        #expect(notes.map(\.channel) == [MIDIExport.drumChannel, MIDIExport.drumChannel])
        #expect(notes.map(\.start) == [0, 4 * ticksPerStep])
        #expect(notes.map(\.velocity) == [127, 50])
        #expect(notes.map(\.duration) == [ticksPerStep, 2 * ticksPerStep])
    }

    @Test func theDrumMapIsNamedInTheOutputNotLeftImplied() throws {
        #expect(
            try exported5().warnings.contains {
                $0.contains("chromatic from 36 (assumed - not in file)")
            })
    }

    @Test func aCustomDrumMapMovesTheExportedNotes() throws {
        let options = try ExportOptions(drumMap: DrumMap.custom(Array(60..<84)), passes: 1)
        let result = try MIDIExport.exportProject(project5(), options: options)
        #expect(try played(result.midi, "Track 1 (drum)").map(\.note) == [60, 60])
        #expect(result.warnings.contains { $0.contains("custom (assumed - not in file)") })
    }

    @Test func timeShiftMovesNotesOffTheGrid() throws {
        let shifted = try played(exported5().midi, "Track 3").map(\.start)
        let grid = try played(exported5Flat().midi, "Track 3").map(\.start)

        #expect(zip(shifted, grid).map(-) == project5RampTicks)
        #expect(grid == project5Steps.map { $0 * ticksPerStep })
    }

    @Test func theShiftDoesNotScaleWithTheStepSize() throws {
        let eighths = try MIDIExport.exportProject(
            withBits(project5(), raw: 12), options: onePass())
        let grid = try MIDIExport.exportProject(
            withBits(project5(), raw: 12),
            options: ExportOptions(applyTimeShift: false, passes: 1))

        let offsets = try zip(
            played(eighths.midi, "Track 3").map(\.start),
            played(grid.midi, "Track 3").map(\.start)
        ).map(-)
        #expect(offsets == project5RampTicks)
    }

    @Test func aShiftBeforeTheStartIsHeldAtIt() throws {
        let result = try exported5()
        #expect(try played(result.midi, "Track 1 (drum)")[0].start == 0)
        #expect(result.diagnostics.entries.contains { $0.code == .timeShiftClipped })
    }

    @Test func swingAndTimeShiftAdd() throws {
        let swung = try withSwing(project5(), 75)
        let both = try MIDIExport.exportProject(swung, options: onePass())
        let swingOnly = try MIDIExport.exportProject(
            swung, options: ExportOptions(applyTimeShift: false, passes: 1))
        let shiftOnly = try MIDIExport.exportProject(project5(), options: onePass())
        let grid = try MIDIExport.exportProject(
            project5(), options: ExportOptions(applyTimeShift: false, passes: 1))

        func starts(_ result: ExportResult) throws -> [Int] {
            try played(result.midi, "Track 3").map(\.start)
        }
        let base = try starts(grid)
        let swingAlone = try zip(starts(swingOnly), base).map(-)
        let shiftAlone = try zip(starts(shiftOnly), base).map(-)
        let together = try zip(starts(both), base).map(-)

        #expect(together == zip(swingAlone, shiftAlone).map(+))
    }

    @Test func patternsAreLaidEndToEndAndStayAlignedAcrossTracks() throws {
        let result = try MIDIExport.exportProject(project9(), options: onePass())
        #expect(result.patternNumbers == [2, 3])

        let drums = try played(result.midi, "Track 1 (drum)")
        let melodic = try played(result.midi, "Track 3")

        #expect(drums[0].start == 0)
        #expect(melodic[0].start == 0)
        #expect(drums[1].start == 16 * ticksPerStep)
        #expect(melodic[0].note == 60)
        #expect(drums[0].duration == 4 * ticksPerStep)
    }

    @Test func theFileLastsAsLongAsItsPatterns() throws {
        let arrangement = try MIDIExport.arrange(
            MIDIExport.renderProject(project9(), options: onePass()))
        #expect(arrangement.lengthTicks == 32 * ticksPerStep)
    }

    @Test func aMarkerNamesTheStartOfEveryPattern() throws {
        let found = try markers(MIDIExport.exportProject(project9(), options: onePass()).midi)
        #expect(found.map(\.tick) == [0, 16 * ticksPerStep])
        #expect(found.map(\.text) == ["pattern 2", "pattern 3"])
    }

    @Test func theConductorTrackStillEndsWhereTheMusicDoes() throws {
        let midi = try MIDIExport.exportProject(project9(), options: onePass()).midi
        let conductor = midi.tracks[0]
        let events = conductor.events.reduce(0) { $0 + Int($1.delta.ticks(using: midi.timebase)) }
        let end = Int(conductor.deltaTimeBeforeEndOfTrack.ticks(using: midi.timebase))
        #expect(events + end == 32 * ticksPerStep)
    }

    @Test func theMarkersCanBeLeftOut() throws {
        let midi = try MIDIExport.exportProject(
            project9(), options: ExportOptions(markers: false, passes: 1)
        ).midi
        #expect(markers(midi).isEmpty)
        let conductor = midi.tracks[0]
        let end = Int(conductor.deltaTimeBeforeEndOfTrack.ticks(using: midi.timebase))
        #expect(end == 32 * ticksPerStep)
    }

    @Test func aSplitFileIsMarkedWithThePatternItHolds() throws {
        let results = try MIDIExport.exportSplit(project9(), options: onePass())
        #expect(
            results.map { markers($0.midi).map(\.text) } == [
                ["pattern 2"], ["pattern 3"], ["pattern 2"],
            ])
        #expect(results.allSatisfy { markers($0.midi).allSatisfy { $0.tick == 0 } })
    }

    @Test func aMaskedNoteLandsOnTheRepeatItPlaysIn() throws {
        let result = try MIDIExport.exportProject(project9())
        let drums = try played(result.midi, "Track 1 (drum)")

        // Pattern 3 expands to four repeats, so its masked note sits one pass into them.
        #expect(drums.map(\.start) == [0, 32 * ticksPerStep])
        #expect(result.warnings.contains { $0.contains("rendered as 4 repeats") })

        let arrangement = try MIDIExport.arrange(MIDIExport.renderProject(project9()))
        #expect(arrangement.lengthTicks == 80 * ticksPerStep)
    }

    @Test func aGateOffTheLadderFallsBackToTheDeviceDefaultAndSaysSo() throws {
        let pattern = try initialProject().track(1).pattern(1)
        let rendering = try MIDIExport.renderPattern(
            drumGatesOffTheLadder(pattern), trackNumber: 1, kind: .drum)

        #expect(!rendering.notes.isEmpty)
        #expect(
            rendering.warnings.contains { $0.contains("gate encoding 200 is off the 0-127 ladder") }
        )
        #expect(
            rendering.notes.allSatisfy {
                $0.durationTicks == Arithmetic.pyRound(0.5 * Double(ticksPerStep))
            })
    }

    @Test func readerWarningsSurviveIntoTheExport() throws {
        let result = try MIDIExport.exportProject(
            initialProject(), options: ExportOptions(includeStale: true, includeDisabled: true))
        #expect(result.warnings.contains { $0.contains("holds both melodic") })
        #expect(result.warnings.contains { $0.contains("disabled note(s), step turned off") })
    }

    @Test func theExportReplacesAReaderLineRatherThanEchoingIt() throws {
        let diagnostics = try MIDIExport.exportProject(initialProject()).diagnostics

        for (readerCode, exportCode) in [
            (Code.disabledStepOff, Code.disabledNotExported),
            (Code.mixedNoteSets, Code.staleNoteSet),
        ] {
            let spokenFor = Set(
                diagnostics.entries.filter { $0.code == exportCode }.map(\.site.pattern))
            #expect(!spokenFor.isEmpty, "\(exportCode) should fire on initial_project")
            let clashes = Set(
                diagnostics.entries.filter { $0.code == readerCode }.map(\.site.pattern)
            ).intersection(spokenFor)
            #expect(clashes.isEmpty, "\(readerCode) repeated")
        }

        #expect(diagnostics.messages.contains { $0.contains("--include-stale exports both") })
        #expect(diagnostics.messages.contains { $0.contains("--include-disabled exports them") })
    }

    @Test func onlyTheSetTheDevicePlaysIsExported() throws {
        let project = try initialProject().select(tracks: [1], patterns: [1])

        let live = try MIDIExport.exportProject(project)
        #expect(live.trackNames == ["Track 1 (drum)"])
        #expect(live.warnings.contains { $0.contains("not exported (--include-stale") })

        let both = try MIDIExport.exportProject(
            project, options: ExportOptions(includeStale: true))
        #expect(both.trackNames == ["Track 1", "Track 1 (drum)"])
        #expect(both.noteCount > live.noteCount)
    }

    /// No sample project pairs drum mode with a melody-only pattern, so the case is built.
    @Test func aPatternHoldingOneSetIsExportedWhateverTheModeFlagSays() throws {
        let melodic = try project5().select(tracks: [3])
        let original = melodic.tracks[0]
        let inDrumMode = Project(
            device: melodic.device, version: melodic.version, tempoBPM: melodic.tempoBPM,
            globalSwingPercent: melodic.globalSwingPercent, currentScene: melodic.currentScene,
            tracks: [
                Track(
                    number: original.number, itemID: original.itemID,
                    patterns: original.patterns, drumMode: true)
            ],
            scenes: melodic.scenes, sourceName: melodic.sourceName,
            diagnostics: melodic.diagnostics)

        let result = try MIDIExport.exportProject(inDrumMode, options: onePass())
        #expect(result.trackNames == ["Track 3"])
        #expect(result.noteCount == 10)
    }

    @Test func anEmptyProjectExportsNothing() throws {
        let result = try MIDIExport.exportProject(Samples.project("Default"))
        #expect(result.isEmpty)
        #expect(result.trackNames.isEmpty)
    }

    @Test func selectionNarrowsWhatIsExported() throws {
        let result = try MIDIExport.exportProject(
            project5().select(tracks: [3]), options: onePass())
        #expect(result.trackNames == ["Track 3"])
        #expect(result.noteCount == 10)
    }

    @Test func swingDelaysTheSecondStepOfEachPair() throws {
        let swung = try withSwing(project5(), 75)
        let grid = try MIDIExport.exportProject(
            swung, options: ExportOptions(applySwing: false, passes: 1))
        let result = try MIDIExport.exportProject(swung, options: onePass())

        let offsets = try zip(
            played(result.midi, "Track 3").map(\.start), played(grid.midi, "Track 3").map(\.start)
        ).map(-)
        let steps = [1, 2, 3, 4, 5, 6, 7, 8, 9, 13]
        #expect(offsets == steps.map { $0 % 2 == 0 ? ticksPerStep / 2 : 0 })
        #expect(result.warnings.contains { $0.contains("75% swing") })
    }

    /// Export subtracts one before calling; the import planner is already 0-based and does not.
    @Test func swingDelayIsZeroBasedAndBothDirectionsShareIt() {
        #expect(MIDIExport.swingDelay(0, 75, 120) == 0)
        #expect(MIDIExport.swingDelay(1, 75, 120) == 60)
        #expect(MIDIExport.swingDelay(2, 75, 120) == 0)
        #expect(MIDIExport.swingDelay(0, 50, 120) == 0)
        #expect(MIDIExport.swingDelay(1, 50, 120) == 0)
    }

    @Test func aGlobalSwingIsReportedRatherThanApplied() throws {
        let base = try project5()
        let swung = Project(
            device: base.device, version: base.version, tempoBPM: base.tempoBPM,
            globalSwingPercent: 63, currentScene: base.currentScene, tracks: base.tracks,
            scenes: base.scenes, sourceName: base.sourceName, diagnostics: base.diagnostics)
        let result = try MIDIExport.exportProject(swung, options: onePass())
        let baseline = try MIDIExport.exportProject(base, options: onePass())

        #expect(result.warnings.contains { $0.contains("63% global swing") })
        #expect(
            try played(result.midi, "Track 3").map(\.start)
                == played(baseline.midi, "Track 3").map(\.start))
    }

    @Test func aStraightGlobalSwingIsNotReported() throws {
        let result = try MIDIExport.exportProject(project5(), options: onePass())
        #expect(!result.warnings.contains { $0.contains("global swing") })
    }

    @Test func stepSizeComesFromThePatternItself() throws {
        let eighths = try MIDIExport.exportProject(
            withBits(project5(), raw: 12), options: flat())
        #expect(try Array(played(eighths.midi, "Track 3").map(\.start).prefix(2)) == [0, 240])
    }

    @Test func aTripletPatternRendersTwoThirdsOfTheStep() throws {
        let triplets = try MIDIExport.exportProject(
            withBits(project5(), raw: 21), options: flat())
        #expect(try Array(played(triplets.midi, "Track 3").map(\.start).prefix(2)) == [0, 80])
    }

    @Test func aNonForwardDirectionIsReportedNotReordered() throws {
        let walking = try MIDIExport.exportProject(
            withBits(project5(), raw: 84), options: flat())
        #expect(
            try Array(played(walking.midi, "Track 3").map(\.start).prefix(2))
                == [0, ticksPerStep])
        #expect(walking.warnings.contains { $0.contains("walk") })
    }

    @Test func theChromaticDrumMapBaseIsConfigurable() throws {
        let result = try MIDIExport.exportProject(
            project5(), options: ExportOptions(drumMap: DrumMap.chromatic(60), passes: 1))
        #expect(try played(result.midi, "Track 1 (drum)")[0].note == 60)
    }

    @Test(
        arguments: [
            (0, 480, 10, Constants.defaultGateLength, 1, "at least 1"),
            (100, 480, 10, Constants.defaultGateLength, 1, "not divisible"),
            (480, 480, 10, Constants.defaultGateLength, 5, "passes must be 1-4"),
            (480, 480, 16, Constants.defaultGateLength, 1, "0-15"),
            (480, 480, 10, 0.0, 1, "greater than 0"),
        ])
    func optionsThatCannotProduceExactTimingAreRejected(
        _ testCase: (Int, Int, Int, Double, Int, String)
    ) {
        let (ticks, _, channel, gate, passes, message) = testCase
        let thrown = #expect(throws: KSPError.self) {
            try ExportOptions(
                ticksPerBeat: ticks, drumChannel: channel, defaultGate: gate, passes: passes)
        }
        #expect(thrown?.description.contains(message) == true)
    }

    @Test(arguments: [0, 11]) func aRepeatCountOutsideTheRangeIsRejected(_ count: Int) {
        let thrown = #expect(throws: KSPError.self) {
            try ExportOptions(repeatCount: count)
        }
        #expect(thrown?.description.contains("repeat must be 1-10") == true)
    }

    @Test func theFallbackLengthIsTheCallersToName() throws {
        let real = try initialProject().track(1).pattern(1)
        let corrupt = drumGatesOffTheLadder(real)
        let options = try ExportOptions(defaultGate: 1.0)

        let measured = try MIDIExport.renderPattern(
            real, trackNumber: 1, kind: .drum, options: options)
        let doubled = try MIDIExport.renderPattern(
            corrupt, trackNumber: 1, kind: .drum, options: options)

        #expect(!measured.warnings.contains { $0.contains("default length") })
        #expect(doubled.notes.allSatisfy { $0.durationTicks == ticksPerStep })
        #expect(doubled.warnings.contains { $0.contains("1-step default") })
    }

    @Test func tracksOfDifferentTotalLengthsAreReported() throws {
        let result = try MIDIExport.exportProject(project9())
        #expect(
            result.warnings.contains {
                $0.contains("different total lengths") && $0.contains("drift apart")
            })

        let alone = try MIDIExport.exportProject(project9().select(tracks: [1]))
        #expect(!alone.warnings.contains { $0.contains("different total lengths") })
    }

    @Test func theWrittenFileReadsBackIdentically() throws {
        let result = try exported5()
        let reloaded = try MusicalMIDI1File(data: result.midi.rawData())
        #expect(try played(reloaded, "Track 3") == played(result.midi, "Track 3"))
        #expect(try played(reloaded, "Track 1 (drum)") == played(result.midi, "Track 1 (drum)"))
    }
}

@Suite struct RenderLayerTests {
    @Test func aPatternRendersFromItsOwnTickZero() throws {
        let rendering = try MIDIExport.renderPattern(
            project5().track(3).pattern(1), trackNumber: 3, kind: .seq, options: onePass())

        #expect(rendering.patternNumber == 1)
        #expect(rendering.lengthTicks == 16 * ticksPerStep)
        #expect(rendering.midiTrackName == "Track 3")
        #expect(
            rendering.notes.map(\.pitch)
                == Array(repeating: 48, count: 4) + [49, 49, 49, 49, 50, 50])
        #expect(rendering.notes.map(\.tick) == rampedStarts)
        #expect(rendering.notes.map(\.velocity) == [60, 70, 90, 100, 60, 70, 90, 100, 60, 120])
        #expect(Set(rendering.notes.map(\.channel)) == [2])
    }

    @Test func gateIsADurationInSteps() throws {
        let rendering = try MIDIExport.renderPattern(
            project5().track(3).pattern(1), trackNumber: 3, kind: .seq, options: onePass())
        #expect(rendering.notes[8].durationTicks == 4 * ticksPerStep)
        #expect(
            rendering.notes[9].durationTicks == Arithmetic.pyRound(3.5 * Double(ticksPerStep)))
    }

    @Test func theDrumSetRendersOntoTheDrumChannel() throws {
        let rendering = try MIDIExport.renderPattern(
            project5().track(1).pattern(1), trackNumber: 1, kind: .drum, options: onePass())
        #expect(rendering.midiTrackName == "Track 1 (drum)")
        #expect(
            rendering.notes.map(\.pitch) == [
                DrumMap.defaultChromaticLow, DrumMap.defaultChromaticLow,
            ])
        #expect(Set(rendering.notes.map(\.channel)) == [MIDIExport.drumChannel])
    }

    @Test func anArrangementCanBeBuiltWithoutTouchingTheMIDILibrary() throws {
        let arrangement = try MIDIExport.arrange(
            MIDIExport.renderProject(project5(), options: onePass()))

        #expect(arrangement.tracks.map(\.name) == ["Track 1 (drum)", "Track 3"])
        #expect(arrangement.noteCount == 12)
        #expect(arrangement.lengthTicks == 16 * ticksPerStep)
        #expect(arrangement.patternNumbers == [1])
        #expect(arrangement.trackNumbers == [1, 3])

        let midi = MIDIExport.buildMIDIFile(
            arrangement, name: "x", tempoBPM: 120.0, ticksPerBeat: 480)
        #expect(midi.tracks.compactMap(\.name) == ["x", "Track 1 (drum)", "Track 3"])
        #expect(try played(midi, "Track 3").count == 10)
    }
}

/// A repeat lays the whole arrangement down again; `passes` is the device's own step-skip cycle.
@Suite struct RepeatTests {
    /// project_9's two 16-step patterns: one pass of the material.
    let cycle = 32 * ticksPerStep

    @Test func oneRepeatIsWhatTheLayerAlreadyDid() throws {
        let renderings = try MIDIExport.renderProject(project9(), options: onePass())
        #expect(try MIDIExport.arrange(renderings, repeat: 1) == MIDIExport.arrange(renderings))
    }

    @Test func repeatsLieEndToEndAndStayAlignedAcrossTracks() throws {
        let renderings = try MIDIExport.renderProject(project9(), options: onePass())
        let once = try MIDIExport.arrange(renderings)
        let thrice = try MIDIExport.arrange(renderings, repeat: 3)

        #expect(thrice.lengthTicks == 3 * cycle)
        #expect(thrice.noteCount == 3 * once.noteCount)
        #expect(thrice.tracks.map(\.name) == once.tracks.map(\.name))
        for (original, repeated) in zip(once.tracks, thrice.tracks) {
            #expect(
                repeated.notes.map(\.tick)
                    == (0..<3).flatMap { repetition in
                        original.notes.map { $0.tick + repetition * cycle }
                    })
        }
    }

    @Test func everyRoundIsMarkedButThePatternListIsNot() throws {
        let arrangement = try MIDIExport.arrange(
            MIDIExport.renderProject(project9(), options: onePass()), repeat: 3)

        #expect(
            arrangement.boundaries
                == (0..<3).flatMap { repetition in
                    [(2, 0), (3, 16 * ticksPerStep)].map { number, offset in
                        PatternBoundary(patternNumber: number, tick: repetition * cycle + offset)
                    }
                })
        #expect(arrangement.patternNumbers == [2, 3])
    }

    @Test(arguments: [-1, 0, 11]) func aCountOutsideTheRangeIsRejected(_ count: Int) throws {
        let renderings = try MIDIExport.renderProject(project9(), options: onePass())
        let thrown = #expect(throws: KSPError.self) {
            try MIDIExport.arrange(renderings, repeat: count)
        }
        #expect(thrown?.description.contains("repeat must be 1-10") == true)
    }

    @Test func awholeExportHonoursTheOption() throws {
        let once = try MIDIExport.exportProject(project9(), options: onePass())
        let twice = try MIDIExport.exportProject(
            project9(), options: ExportOptions(passes: 1, repeatCount: 2))

        #expect(twice.noteCount == 2 * once.noteCount)
        #expect(twice.patternNumbers == once.patternNumbers)
    }

    @Test func eachSplitFileIsRepeatedToo() throws {
        let once = try MIDIExport.exportSplit(project9(), options: onePass())
        let twice = try MIDIExport.exportSplit(
            project9(), options: ExportOptions(passes: 1, repeatCount: 2))

        #expect(twice.map(\.patternNumbers) == once.map(\.patternNumbers))
        #expect(twice.map(\.noteCount) == once.map { 2 * $0.noteCount })
    }

    @Test func theMaterialsOwnDiagnosticsAreNotRepeated() throws {
        let renderings = try MIDIExport.renderProject(project9(), options: onePass())
        #expect(
            try MIDIExport.arrange(renderings, repeat: 3).warnings
                == MIDIExport.arrange(renderings).warnings)
    }

    @Test func agateHeldPastTheEndOfAroundMeetsTheNextOne() throws {
        let length = 16 * ticksPerStep
        let held = Rendering(
            trackNumber: 1, kind: .seq, patternNumber: 1,
            notes: [
                RenderedNote(
                    tick: 0, durationTicks: length + 600, pitch: 60, velocity: 100, channel: 0)
            ],
            lengthTicks: length)
        let arrangement = try MIDIExport.arrange([held], repeat: 3)
        let notes = arrangement.tracks[0].notes

        #expect(notes.map(\.tick) == [0, length, 2 * length])
        #expect(notes.map(\.durationTicks) == [length, length, length + 600])
        #expect(arrangement.warnings.contains { $0.contains("own note-off") })
    }

    @Test func aclippedTimeShiftIsClippedOnlyWhereThereIsNoRoom() throws {
        let length = 16 * ticksPerStep
        let early = Rendering(
            trackNumber: 1, kind: .seq, patternNumber: 1,
            notes: [
                RenderedNote(tick: -5, durationTicks: 120, pitch: 60, velocity: 100, channel: 0)
            ],
            lengthTicks: length)
        let arrangement = try MIDIExport.arrange([early], repeat: 3)

        #expect(arrangement.tracks[0].notes.map(\.tick) == [0, length - 5, 2 * length - 5])
        #expect(arrangement.warnings.count { $0.contains("held at the start") } == 1)
    }
}

@Suite struct SplitTests {
    @Test func oneResultPerTrackAndPattern() throws {
        let results = try MIDIExport.exportSplit(project9())

        #expect(results.map(\.trackNumbers) == [[1], [1], [3]])
        #expect(results.map(\.patternNumbers) == [[2], [3], [2]])
        #expect(results.allSatisfy { $0.noteCount == 1 })
    }

    @Test func eachFileStartsAtTickZero() throws {
        let merged = try played(
            MIDIExport.exportProject(project9(), options: onePass()).midi, "Track 1 (drum)")
        #expect(merged.map(\.start) == [0, 16 * ticksPerStep])

        let pattern3 = try #require(
            MIDIExport.exportSplit(project9(), options: onePass())
                .first { $0.patternNumbers == [3] })
        #expect(try played(pattern3.midi, "Track 1 (drum)").map(\.start) == [0])
    }

    @Test func aSplitFileHoldsOnlyItsOwnTrack() throws {
        let results = try MIDIExport.exportSplit(project5())
        #expect(results.map(\.trackNames) == [["Track 1 (drum)"], ["Track 3"]])
    }

    @Test func bothNoteSetsOfOnePatternStayInOneFile() throws {
        let project = try initialProject().select(tracks: [1], patterns: [1])
        let results = try MIDIExport.exportSplit(
            project, options: ExportOptions(includeStale: true))
        #expect(results.count == 1)
        #expect(results.first?.trackNames == ["Track 1", "Track 1 (drum)"])
    }

    @Test func anEmptyProjectProducesNoFiles() throws {
        #expect(try MIDIExport.exportSplit(Samples.project("Default")).isEmpty)
    }
}

@Suite struct FlatVelocityTests {
    /// project_5 track 3 pattern 1, read off the device display.
    let stored = [60, 70, 90, 100, 60, 70, 90, 100, 60, 120]

    private func seq(_ project: Project, _ options: ExportOptions) throws -> Rendering {
        try MIDIExport.renderPattern(
            project.track(3).pattern(1), trackNumber: 3, kind: .seq, options: options)
    }

    @Test func theSubstituteIsTheMeasuredDeviceValue() {
        #expect(MIDIExport.defaultFlatVelocity == Constants.freshVelocity)
    }

    @Test func unsetKeepsEveryStoredVelocity() throws {
        #expect(try seq(project5(), onePass()).notes.map(\.velocity) == stored)
    }

    @Test func setReplacesAllOfThem() throws {
        let options = try ExportOptions(passes: 1, flatVelocity: MIDIExport.defaultFlatVelocity)
        #expect(
            try seq(project5(), options).notes.map(\.velocity)
                == Array(repeating: MIDIExport.defaultFlatVelocity, count: 10))
    }

    /// `minVelocity` only rescues a stored velocity that is being kept.
    @Test(arguments: [0, 1]) func aStoredFloorValueIsReplacedRatherThanClamped(_ value: Int) throws
    {
        let quiet = try withVelocity(project5().track(3).pattern(1), value)
        let flat = try ExportOptions(passes: 1, flatVelocity: MIDIExport.defaultFlatVelocity)

        func render(_ options: ExportOptions) throws -> [Int] {
            try MIDIExport.renderPattern(quiet, trackNumber: 3, kind: .seq, options: options)
                .notes.map(\.velocity)
        }

        #expect(try render(onePass()) == Array(repeating: MIDIExport.minVelocity, count: 10))
        #expect(try render(flat) == Array(repeating: MIDIExport.defaultFlatVelocity, count: 10))
    }

    @Test func theDrumSetFlattensToo() throws {
        let drums = try project5().track(1).pattern(1)
        let options = try ExportOptions(passes: 1, flatVelocity: MIDIExport.defaultFlatVelocity)

        let stored = try MIDIExport.renderPattern(
            drums, trackNumber: 1, kind: .drum, options: onePass())
        let flat = try MIDIExport.renderPattern(
            drums, trackNumber: 1, kind: .drum, options: options)

        #expect(stored.notes.map(\.velocity) == [127, 50])
        #expect(
            flat.notes.map(\.velocity) == Array(repeating: MIDIExport.defaultFlatVelocity, count: 2)
        )
    }

    @Test(arguments: [-1, 0, 128]) func aVelocityOutsideTheRangeIsRejected(_ value: Int) throws {
        let thrown = #expect(throws: KSPError.self) {
            try ExportOptions(flatVelocity: value)
        }
        #expect(thrown?.description.contains("flat_velocity must be 1-127") == true)
    }

    @Test func zeroIsRefusedAsANoteOffRatherThanSilenced() throws {
        let thrown = #expect(throws: KSPError.self) { try ExportOptions(flatVelocity: 0) }
        #expect(
            thrown?.description.contains("0 is a MIDI note-off, not a silent note") == true)
    }

    @Test func nothingElseAboutTheRenderingMoves() throws {
        let pattern = try drumGatesOffTheLadder(initialProject().track(1).pattern(1))
        let options = try ExportOptions(flatVelocity: MIDIExport.defaultFlatVelocity)

        let stored = try MIDIExport.renderPattern(pattern, trackNumber: 1, kind: .drum)
        let flat = try MIDIExport.renderPattern(
            pattern, trackNumber: 1, kind: .drum, options: options)

        #expect(flat.warnings == stored.warnings)
        #expect(flat.warnings.contains { $0.contains("off the 0-127 ladder") })
        #expect(flat.notes.map(\.tick) == stored.notes.map(\.tick))
        #expect(flat.notes.map(\.durationTicks) == stored.notes.map(\.durationTicks))
    }

    @Test func theAutoPassPathKeepsTheFixedVelocity() throws {
        let renderings = try MIDIExport.renderProject(
            project5(), options: ExportOptions(flatVelocity: MIDIExport.defaultFlatVelocity))

        #expect(renderings.contains { $0.notes.count > 10 })
        #expect(
            renderings.allSatisfy {
                $0.notes.allSatisfy { $0.velocity == MIDIExport.defaultFlatVelocity }
            })
    }
}

/// The ladder covers all of 0-127, so only a value the device could not write hits the fallback.
private func drumGatesOffTheLadder(_ pattern: Pattern, raw: Int = 200) -> Pattern {
    let notes = pattern.notes.map { note -> Note in
        guard note.kind == .drum else { return note }
        return Note(
            kind: note.kind, slot: note.slot, index: note.index, step: note.step,
            pitch: note.pitch, velocity: note.velocity, gateRaw: raw, gate: nil,
            timeShift: note.timeShift, randomness: note.randomness, skip: note.skip,
            active: note.active)
    }
    return replacing(pattern, notes: notes)
}

/// No sample project uses swing, so the only way to cover it is to build the case.
private func withSwing(_ project: Project, _ percent: Int) -> Project {
    replacingPattern1OfTrack3(project) { pattern in
        replacing(pattern, seqSwingPercent: percent)
    }
}

/// Every sample project holds the same 20, so a non-default step size can only be built.
private func withBits(_ project: Project, raw: Int) -> Project {
    replacingPattern1OfTrack3(project) { pattern in
        replacing(pattern, seqBits: PatternBits.decode(raw))
    }
}

private func replacingPattern1OfTrack3(
    _ project: Project, _ transform: (Pattern) -> Pattern
) -> Project {
    let tracks = project.tracks.map { track -> Track in
        guard track.number == 3 else { return track }
        let patterns = track.patterns.map { $0.number == 1 ? transform($0) : $0 }
        return Track(
            number: track.number, itemID: track.itemID, patterns: patterns,
            drumMode: track.drumMode)
    }
    return Project(
        device: project.device, version: project.version, tempoBPM: project.tempoBPM,
        globalSwingPercent: project.globalSwingPercent, currentScene: project.currentScene,
        tracks: tracks, scenes: project.scenes, sourceName: project.sourceName,
        diagnostics: project.diagnostics)
}

private func replacing(
    _ pattern: Pattern, notes: [Note]? = nil, seqSwingPercent: Int? = nil,
    seqBits: PatternBits? = nil
) -> Pattern {
    Pattern(
        number: pattern.number, mode: pattern.mode, hasData: pattern.hasData,
        seqStepCount: pattern.seqStepCount,
        seqSwingPercent: seqSwingPercent ?? pattern.seqSwingPercent,
        seqBits: seqBits ?? pattern.seqBits, drumStepCount: pattern.drumStepCount,
        drumSwingPercent: pattern.drumSwingPercent, drumBits: pattern.drumBits,
        rootNote: pattern.rootNote, scale: pattern.scale, notes: notes ?? pattern.notes,
        diagnostics: pattern.diagnostics)
}

private func withVelocity(_ pattern: Pattern, _ velocity: Int) -> Pattern {
    let notes = pattern.notes.map { note in
        Note(
            kind: note.kind, slot: note.slot, index: note.index, step: note.step,
            pitch: note.pitch, velocity: velocity, gateRaw: note.gateRaw, gate: note.gate,
            timeShift: note.timeShift, randomness: note.randomness, skip: note.skip,
            active: note.active)
    }
    return replacing(pattern, notes: notes)
}
