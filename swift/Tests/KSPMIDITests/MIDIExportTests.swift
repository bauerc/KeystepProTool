import Foundation
import KSPKit
import SwiftMIDIFile
import Testing

@testable import KSPMIDI

/// MIDI export, checked against the hardware-confirmed project descriptions. A port of
/// `tests/test_midi_export.py`.
///
/// `project_5` is the reference case: its notes, velocities, gates and step positions were read off
/// the device display, so the exported file can be asserted note by note rather than against
/// another piece of our own code.

/// The 480/4 default: 1/16 steps at 480 ticks per beat.
private let ticksPerStep = 120

/// project_5 and project_9 carry real skip masks, so anything asserting one pattern's own content
/// has to say which repeat it means.
private func onePass() throws -> ExportOptions { try ExportOptions(passes: 1) }

/// Grid only. For tests whose subject is the step size, not the groove.
private func flat() throws -> ExportOptions { try ExportOptions(applyTimeShift: false) }

/// project_5 Track 3 pattern 1, 0-based. The tenth note sits at step 13, which is what proves the
/// two index spaces are different.
private let project5Steps = [0, 1, 2, 3, 4, 5, 6, 7, 8, 12]

/// The same notes' time shifts (+1..+4, -1..-4, 0, +2) in ticks, at the unit tier 8 measured --
/// 1/400 of a beat, so 1.2 ticks each at 480, rounded.
private let project5RampTicks = [1, 2, 4, 5, -1, -2, -4, -5, 0, 2]

/// Where those notes land once the shift is applied, which is the default.
private let rampedStarts = zip(project5Steps, project5RampTicks).map { $0 * ticksPerStep + $1 }

private func project5() throws -> Project { try Samples.project("project_5") }
private func project9() throws -> Project { try Samples.project("project_9") }
private func initialProject() throws -> Project { try Samples.project("initial_project") }

/// One pass, so these assertions read the pattern rather than the cycle.
private func exported5() throws -> ExportResult {
    try MIDIExport.exportProject(project5(), options: onePass())
}

/// The same, with the time shift left off. project_5 is the only sample carrying a shift, so every
/// test whose subject is something else reads the grid here rather than the groove.
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

    /// Track 1's drum set and a melodic track cannot share a MIDI track: they need different
    /// channels and their pitch values mean different things -- a lane index is not a MIDI note.
    @Test func eachTrackAndParameterSetBecomesItsOwnMIDITrack() throws {
        #expect(try exported5().trackNames == ["Track 1 (drum)", "Track 3"])
    }

    /// project_5 Track 3 pattern 1, straight from the description file. Beats 1-4 are C2 (48), 5-8
    /// are C#2 (49), and two D (50) notes sit at beats 9 and 13 -- the second of which is the note
    /// that proves the two index spaces, since it lives at note index 10 but step 13.
    @Test func melodicNotesMatchTheDocumentedDescription() throws {
        let notes = try played(exported5().midi, "Track 3")

        #expect(notes.map(\.note) == Array(repeating: 48, count: 4) + [49, 49, 49, 49, 50, 50])
        #expect(notes.map(\.velocity) == [60, 70, 90, 100, 60, 70, 90, 100, 60, 120])
        #expect(notes.map(\.start) == rampedStarts)
        #expect(Set(notes.map(\.channel)) == [2])  // Track 3 -> MIDI channel 3
    }

    /// The tie from beat 9 to beat 12 is stored as gate 4 and lasts 4 steps. That is the evidence
    /// the displayed gate is a count of steps, which is what makes a duration derivable at all.
    @Test func gateBecomesNoteLengthInSteps() throws {
        let notes = try played(exported5().midi, "Track 3")
        #expect(notes[8].start == 8 * ticksPerStep)
        #expect(notes[8].duration == 4 * ticksPerStep)
        #expect(notes[9].duration == Arithmetic.pyRound(3.5 * Double(ticksPerStep)))  // gate 3.5
    }

    /// Beat 1 has gate 2 but beat 2 repeats the same pitch. The device retriggers; MIDI would be
    /// left holding one note-on too many. Shortening the earlier note keeps the two equivalent.
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

    /// Kick on beats 1 and 5, velocities 127 and 50, gates 1 and 2.
    @Test func drumLanesMapOntoTheGeneralMIDIPercussionChannel() throws {
        let notes = try played(exported5Flat().midi, "Track 1 (drum)")

        // Lane 0 under the default chromatic-36 map is the GM bass drum.
        #expect(notes.map(\.note) == [DrumMap.defaultChromaticLow, DrumMap.defaultChromaticLow])
        #expect(notes.map(\.channel) == [MIDIExport.drumChannel, MIDIExport.drumChannel])
        #expect(notes.map(\.start) == [0, 4 * ticksPerStep])
        #expect(notes.map(\.velocity) == [127, 50])
        #expect(notes.map(\.duration) == [ticksPerStep, 2 * ticksPerStep])
    }

    /// The map is a device global, not project data (spec 3.2.1). Which one was used is therefore
    /// an assumption, and one the output has to own up to on every export.
    @Test func theDrumMapIsNamedInTheOutputNotLeftImplied() throws {
        #expect(
            try exported5().warnings.contains {
                $0.contains("chromatic from 36 (assumed - not in file)")
            })
    }

    /// The same lane must follow whatever map the user's device actually has.
    @Test func aCustomDrumMapMovesTheExportedNotes() throws {
        let options = try ExportOptions(drumMap: DrumMap.custom(Array(60..<84)), passes: 1)
        let result = try MIDIExport.exportProject(project5(), options: options)
        #expect(try played(result.midi, "Track 1 (drum)").map(\.note) == [60, 60])
        #expect(result.warnings.contains { $0.contains("custom (assumed - not in file)") })
    }

    /// project_5's melodic notes ramp +1..+4 and -1..-4, and the export says so. Measured by tier 8
    /// as 1/400 of a beat per unit, so at 480 the ramp is worth one to five ticks either side.
    @Test func timeShiftMovesNotesOffTheGrid() throws {
        let shifted = try played(exported5().midi, "Track 3").map(\.start)
        let grid = try played(exported5Flat().midi, "Track 3").map(\.start)

        #expect(zip(shifted, grid).map(-) == project5RampTicks)
        #expect(grid == project5Steps.map { $0 * ticksPerStep })
    }

    /// The whole of tier 8: R1 at 1/4 and R3 at 1/16 gave the same tick count. Re-clocking the
    /// pattern to 1/8 moves the steps but must leave each note's displacement alone.
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

    /// project_5's first kick carries -1, and tick -1 does not exist in MIDI. The note keeps its
    /// length and the export reports the clip rather than moving an onset quietly.
    @Test func aShiftBeforeTheStartIsHeldAtIt() throws {
        let result = try exported5()
        #expect(try played(result.midi, "Track 1 (drum)")[0].start == 0)
        #expect(result.diagnostics.entries.contains { $0.code == .timeShiftClipped })
    }

    /// R5: swing 75% and shift +50 together came to exactly their sum.
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

    /// project_9 uses patterns 2 and 3, and pattern 2 on two different tracks. Both tracks'
    /// pattern 2 must start together, and pattern 3 must follow one 16-step pattern later -- not at
    /// its own pattern index, which would leave a bar of silence for the pattern nobody used.
    @Test func patternsAreLaidEndToEndAndStayAlignedAcrossTracks() throws {
        let result = try MIDIExport.exportProject(project9(), options: onePass())
        #expect(result.patternNumbers == [2, 3])

        let drums = try played(result.midi, "Track 1 (drum)")
        let melodic = try played(result.midi, "Track 3")

        #expect(drums[0].start == 0)
        #expect(melodic[0].start == 0)
        #expect(drums[1].start == 16 * ticksPerStep)
        #expect(melodic[0].note == 60)  // C3, as documented
        #expect(drums[0].duration == 4 * ticksPerStep)  // test 1 sets gate 4
    }

    /// Two 16-step patterns at 120 BPM in 1/16 steps: two bars, four seconds.
    ///
    /// The Python asserts `midi.length == 4.0`; `swift-midi-file` exposes no duration property, and
    /// reimplementing mido's tempo walk inside a test would be testing the reimplementation. The
    /// tick length is what determines the seconds anyway -- 3840 ticks at 480 per beat is 8 beats,
    /// four seconds at 120 BPM -- and it is the layer this milestone is meant to assert on.
    @Test func theFileLastsAsLongAsItsPatterns() throws {
        let arrangement = try MIDIExport.arrange(
            MIDIExport.renderProject(project9(), options: onePass()))
        #expect(arrangement.lengthTicks == 32 * ticksPerStep)
    }

    /// The seam between two patterns is invisible in a merged export.
    ///
    /// project_9 holds patterns 2 and 3, so the second marker also proves the text carries the
    /// pattern's own number rather than its position in the file.
    @Test func aMarkerNamesTheStartOfEveryPattern() throws {
        let found = try markers(MIDIExport.exportProject(project9(), options: onePass()).midi)
        #expect(found.map(\.tick) == [0, 16 * ticksPerStep])
        #expect(found.map(\.text) == ["pattern 2", "pattern 3"])
    }

    /// The markers sit in front of end-of-track, whose delta shrinks to suit.
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

    /// Each file starts at its own tick 0, so its one marker names it there.
    @Test func aSplitFileIsMarkedWithThePatternItHolds() throws {
        let results = try MIDIExport.exportSplit(project9(), options: onePass())
        #expect(
            results.map { markers($0.midi).map(\.text) } == [
                ["pattern 2"], ["pattern 3"], ["pattern 2"],
            ])
        #expect(results.allSatisfy { markers($0.midi).allSatisfy { $0.tick == 0 } })
    }

    /// project_9 pattern 3's only hit is masked to 32, i.e. the second repeat. The device runs the
    /// four sequences as repeats of the pattern (spec 5, protocol T5.8), so that note is silent on
    /// the first pass and sounds on the second -- the whole difference between the repeats reading
    /// and the pages one.
    @Test func aMaskedNoteLandsOnTheRepeatItPlaysIn() throws {
        let result = try MIDIExport.exportProject(project9())
        let drums = try played(result.midi, "Track 1 (drum)")

        // Pattern 2 has no masks and stays one pass; pattern 3 expands to four, and its note sits
        // one pass into them.
        #expect(drums.map(\.start) == [0, 32 * ticksPerStep])
        #expect(result.warnings.contains { $0.contains("rendered as 4 repeats") })

        // 16 steps of pattern 2, then four 16-step repeats of pattern 3 -- ten seconds at 120 BPM.
        let arrangement = try MIDIExport.arrange(MIDIExport.renderProject(project9()))
        #expect(arrangement.lengthTicks == 80 * ticksPerStep)
    }

    /// Rounding an undecodable gate to the nearest rung would produce a file that loads cleanly and
    /// plays wrong, so the export uses the length a freshly placed note has and warns.
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

    /// Anything the reader could not resolve makes a MIDI file that may lie.
    @Test func readerWarningsSurviveIntoTheExport() throws {
        let result = try MIDIExport.exportProject(
            initialProject(), options: ExportOptions(includeStale: true, includeDisabled: true))
        #expect(result.warnings.contains { $0.contains("holds both melodic") })
        #expect(result.warnings.contains { $0.contains("disabled note(s), step turned off") })
    }

    /// One finding, one line. The export's versions of these two say what the reader's say *and*
    /// name the flag that undoes them, so printing both would be pure repetition. Each must still
    /// be said exactly once.
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

        // And the surviving line is the one that names the flag.
        #expect(diagnostics.messages.contains { $0.contains("--include-stale exports both") })
        #expect(diagnostics.messages.contains { $0.contains("--include-disabled exports them") })
    }

    /// initial_project Track 1 pattern 1 holds a melody *and* a drum pattern. Parameter 86 bit 6
    /// says the track is in drum mode, so the 64-note melody is leftovers from before it was
    /// switched over -- notes no hardware would play.
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

    /// The flag only decides when *both* sets are populated. A track left in drum mode whose
    /// pattern holds only a melody must still export that melody -- filtering on the flag alone
    /// would silently drop real user data. No sample project has this combination, so it is built.
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

    /// Swing percent is decoded; its timing meaning is the standard one. 75% gives the first step
    /// of a pair three quarters of the pair, so the second starts half a step late.
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

    /// Pins the index space, because export and import count steps differently. The note parameter
    /// numbers steps from 1 and export subtracts one before calling; the import planner is already
    /// 0-based and calls it directly. Aligning the parity to either caller alone silently unswings
    /// the other.
    @Test func swingDelayIsZeroBasedAndBothDirectionsShareIt() {
        #expect(MIDIExport.swingDelay(0, 75, 120) == 0)
        #expect(MIDIExport.swingDelay(1, 75, 120) == 60)
        #expect(MIDIExport.swingDelay(2, 75, 120) == 0)
        #expect(MIDIExport.swingDelay(0, 50, 120) == 0)
        #expect(MIDIExport.swingDelay(1, 50, 120) == 0)
    }

    /// The per-pattern value takes precedence on the device (T7.6), so leaving the global out is
    /// what the hardware does, not caution -- but it still gets named.
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

    /// Bits 3-4 of 99, measured by T5.1 -- so nobody has to supply it.
    @Test func stepSizeComesFromThePatternItself() throws {
        let eighths = try MIDIExport.exportProject(
            withBits(project5(), raw: 12), options: flat())
        #expect(try Array(played(eighths.midi, "Track 3").map(\.start).prefix(2)) == [0, 240])
    }

    /// Bit 0, and why the default resolution is divisible by 3.
    @Test func aTripletPatternRendersTwoThirdsOfTheStep() throws {
        let triplets = try MIDIExport.exportProject(
            withBits(project5(), raw: 21), options: flat())
        #expect(try Array(played(triplets.midi, "Track 3").map(\.start).prefix(2)) == [0, 80])
    }

    /// Rand and Walk have no MIDI equivalent, so the export says so (T5.5).
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

    /// A step that does not land on a whole tick would drift over 64 steps.
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

    /// `defaultGate` names the fallback instead of burying it in the code, and it only ever applies
    /// to gates that did not decode -- a measured one is never overridden.
    @Test func theFallbackLengthIsTheCallersToName() throws {
        let real = try initialProject().track(1).pattern(1)
        let corrupt = drumGatesOffTheLadder(real)
        let options = try ExportOptions(defaultGate: 1.0)

        let measured = try MIDIExport.renderPattern(
            real, trackNumber: 1, kind: .drum, options: options)
        let doubled = try MIDIExport.renderPattern(
            corrupt, trackNumber: 1, kind: .drum, options: options)

        // Every gate in the real pattern decodes now, so --default-gate moves nothing.
        #expect(!measured.warnings.contains { $0.contains("default length") })
        #expect(doubled.notes.allSatisfy { $0.durationTicks == ticksPerStep })
        #expect(doubled.warnings.contains { $0.contains("1-step default") })
    }

    /// Merged, every track restarts at each pattern boundary. The device loops each track on its
    /// own, so once the totals differ the file and the hardware stop agreeing about what plays
    /// together -- worth saying out loud, because nothing in the .mid reveals it.
    @Test func tracksOfDifferentTotalLengthsAreReported() throws {
        let result = try MIDIExport.exportProject(project9())
        #expect(
            result.warnings.contains {
                $0.contains("different total lengths") && $0.contains("drift apart")
            })

        // One track cannot disagree with itself, so the line must not appear.
        let alone = try MIDIExport.exportProject(project9().select(tracks: [1]))
        #expect(!alone.warnings.contains { $0.contains("different total lengths") })
    }

    /// Everything above inspects an in-memory object; a DAW reads bytes.
    @Test func theWrittenFileReadsBackIdentically() throws {
        let result = try exported5()
        let reloaded = try MusicalMIDI1File(data: result.midi.rawData())
        #expect(try played(reloaded, "Track 3") == played(result.midi, "Track 3"))
        #expect(try played(reloaded, "Track 1 (drum)") == played(result.midi, "Track 1 (drum)"))
    }
}

/// The arithmetic layer, asserted as plain data rather than parsed MIDI.
///
/// This is the half that carries the port's risk; keeping it free of `SwiftMIDIFile` is what makes
/// it a translation rather than a redesign.
@Suite struct RenderLayerTests {
    /// project_5 track 3 pattern 1: beats 1-4 C2, 5-8 C#2, then D at beats 9 and 13 -- the second
    /// sitting at note index 10 but step 13.
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

    /// The tie from beat 9 to beat 12 stores gate 4 and lasts four steps.
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

    /// render -> arrange -> build: only the last step knows about MIDI.
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

/// A repeat count exists only in the exported file.
///
/// It is not `passes`: that is the device's own step-skip cycle, capped at four and rendered
/// inside a pattern. This lays the whole arrangement down again, which the hardware has no way to
/// store.
@Suite struct RepeatTests {
    /// project_9's two 16-step patterns, which is one pass of the material.
    let cycle = 32 * ticksPerStep

    @Test func oneRepeatIsWhatTheLayerAlreadyDid() throws {
        let renderings = try MIDIExport.renderProject(project9(), options: onePass())
        #expect(try MIDIExport.arrange(renderings, repeat: 1) == MIDIExport.arrange(renderings))
    }

    /// Every track shifts by the same cycle, so pattern N still starts together on all of them in
    /// the second and third rounds.
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

    /// The marker ruler names every pattern start in every round; the pattern list still answers
    /// which patterns are in the file.
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

    /// The count rides on the options, which is what a CLI flag can set.
    @Test func awholeExportHonoursTheOption() throws {
        let once = try MIDIExport.exportProject(project9(), options: onePass())
        let twice = try MIDIExport.exportProject(
            project9(), options: ExportOptions(passes: 1, repeatCount: 2))

        #expect(twice.noteCount == 2 * once.noteCount)
        #expect(twice.patternNumbers == once.patternNumbers)
    }

    /// A split piece is a clip, and a repeated clip is a looped one: the count means the same
    /// thing wherever the arrangement is laid out.
    @Test func eachSplitFileIsRepeatedToo() throws {
        let once = try MIDIExport.exportSplit(project9(), options: onePass())
        let twice = try MIDIExport.exportSplit(
            project9(), options: ExportOptions(passes: 1, repeatCount: 2))

        #expect(twice.map(\.patternNumbers) == once.map(\.patternNumbers))
        #expect(twice.map(\.noteCount) == once.map { 2 * $0.noteCount })
    }

    /// What a rendering says about itself -- an off-ladder gate, a stale note set, tracks of
    /// unequal length -- describes the material, so a second round of it is not a second finding.
    @Test func theMaterialsOwnDiagnosticsAreNotRepeated() throws {
        let renderings = try MIDIExport.renderProject(project9(), options: onePass())
        #expect(
            try MIDIExport.arrange(renderings, repeat: 3).warnings
                == MIDIExport.arrange(renderings).warnings)
    }

    /// Placing each round rather than copying the first is what makes this work: the seam between
    /// rounds is resolved like any other collision, instead of leaving two note-ons for one pitch
    /// with no note-off between.
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

    /// Only the first round starts at tick 0, so only there does a negative shift have nowhere to
    /// go; later rounds have the room to honour it.
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

/// One file per non-empty (track, pattern), each from its own tick 0.
@Suite struct SplitTests {
    /// project_9 uses pattern 2 on two tracks and pattern 3 on one.
    @Test func oneResultPerTrackAndPattern() throws {
        let results = try MIDIExport.exportSplit(project9())

        #expect(results.map(\.trackNumbers) == [[1], [1], [3]])
        #expect(results.map(\.patternNumbers) == [[2], [3], [2]])
        #expect(results.allSatisfy { $0.noteCount == 1 })
    }

    /// Merged, pattern 3 sits a pattern late; split, it stands alone.
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

    /// --include-stale adds a MIDI track, not a file: same (track, pattern).
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

// MARK: - Case builders

/// Corrupt every drum gate in `pattern`.
///
/// The ladder covers all of 0-127 (spec 6.1), so no sample project can exercise the fallback any
/// more -- the only way in is a value the device could not have written.
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

/// A copy of `project` with one pattern's melodic swing overridden.
///
/// None of the sample projects use swing, so the only way to cover it is to build the case; doing
/// it on the model keeps the sample files untouched.
private func withSwing(_ project: Project, _ percent: Int) -> Project {
    replacingPattern1OfTrack3(project) { pattern in
        replacing(pattern, seqSwingPercent: percent)
    }
}

/// A copy of `project` with track 3 pattern 1's 99 field overridden.
///
/// Every sample project holds the same 20, so a non-default step size, triplet or direction can
/// only be covered by building the case.
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

/// Swift has no `dataclasses.replace`, and `Pattern` has twelve fields, so this stands in for it.
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
