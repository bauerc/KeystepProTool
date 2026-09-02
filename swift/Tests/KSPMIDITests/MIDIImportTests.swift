import Foundation
import KSPKit
import SwiftMIDIFile
import Testing

@testable import KSPMIDI

private let ticksPerBeat = 480
private let ticksPerStep = ticksPerBeat / 4

/// The 16 pitches of `test_file_simple.mid`, in step order.
private let simplePitches = [60, 62, 64, 60, 60, 61, 59, 60, 60, 72, 71, 69, 60, 62, 64, 60]

/// B0-baseline -> T1-note-place, the hardware-measured placement diff.
private let placementRecipe: [String: Int] = [
    "124_40_1": 3,
    "124_48_1_1_1": 1,
    "124_50_1_1_1": 0,
    "124_109_1_1_1": 60,
    "124_110_1_1_1": 7,
    "124_111_1_1_1": 100,
    "124_112_1_1_1": 49,
    "124_113_1_1_1": 100,
]

private func changedTo(_ before: RawProject, _ after: RawProject) -> [String: Int] {
    var moved: [String: Int] = [:]
    for (name, value) in after where before[name] != value {
        if case .int(let now) = value { moved[name] = now }
    }
    return moved
}

private func intAt(_ raw: RawProject, _ name: String) -> Int? {
    if case .int(let number)? = raw[name] { return number }
    return nil
}

private enum EventKind: Int {
    // Python sorts note_off before note_on at the same tick; the rank keeps that order.
    case off = 0
    case on = 1
}

private struct BuiltEvent {
    let tick: Int
    let kind: EventKind
    let pitch: Int
    let velocity: Int
    let channel: Int
}

private func track(from events: [BuiltEvent]) -> MusicalMIDI1File.Track {
    var track = MusicalMIDI1File.Track()
    var previous = 0
    let ordered = events.stableSorted { left, right in
        (left.tick, left.kind.rawValue, left.pitch, left.velocity)
            < (right.tick, right.kind.rawValue, right.pitch, right.velocity)
    }
    for event in ordered {
        let delta = MusicalMIDIFileDeltaTime.ticks(UInt32(event.tick - previous))
        let note = UInt7(event.pitch)
        let channel = UInt4(event.channel)
        track.events.append(
            event.kind == .on
                ? .noteOn(
                    delta: delta, note: note, velocity: .midi1(UInt7(event.velocity)),
                    channel: channel)
                : .noteOff(
                    delta: delta, note: note, velocity: .midi1(UInt7(event.velocity)),
                    channel: channel))
        previous = event.tick
    }
    return track
}

private func clipOf(
    _ events: [(tick: Int, pitch: Int, velocity: Int)], ticksPerQuarterNote: Int = ticksPerBeat,
    length: Int = ticksPerStep
) -> MusicalMIDI1File {
    var built: [BuiltEvent] = []
    for event in events {
        built.append(
            BuiltEvent(
                tick: event.tick, kind: .on, pitch: event.pitch, velocity: event.velocity,
                channel: 0))
        built.append(
            BuiltEvent(
                tick: event.tick + length, kind: .off, pitch: event.pitch, velocity: 64,
                channel: 0))
    }
    return MusicalMIDI1File(
        format: .singleTrack,
        timebase: .init(ticksPerQuarterNote: UInt16(ticksPerQuarterNote)),
        tracks: [track(from: built)])
}

private func songOf(
    _ tracks: [[(tick: Int, pitch: Int, velocity: Int)]], length: Int = ticksPerStep,
    channels: [Int]? = nil
) -> MusicalMIDI1File {
    var built: [MusicalMIDI1File.Track] = []
    for (number, events) in tracks.enumerated() {
        let channel = channels.map { $0[number] } ?? 0
        var timed: [BuiltEvent] = []
        for event in events {
            timed.append(
                BuiltEvent(
                    tick: event.tick, kind: .on, pitch: event.pitch, velocity: event.velocity,
                    channel: channel))
            timed.append(
                BuiltEvent(
                    tick: event.tick + length, kind: .off, pitch: event.pitch, velocity: 64,
                    channel: channel))
        }
        built.append(track(from: timed))
    }
    return MusicalMIDI1File(
        format: .multipleTracksSynchronous,
        timebase: .init(ticksPerQuarterNote: UInt16(ticksPerBeat)), tracks: built)
}

private func mixedOf(
    _ events: [(tick: Int, pitch: Int, channel: Int)], length: Int = ticksPerStep,
    format: MIDI1FileFormat = .singleTrack
) -> MusicalMIDI1File {
    var built: [BuiltEvent] = []
    for event in events {
        built.append(
            BuiltEvent(
                tick: event.tick, kind: .on, pitch: event.pitch, velocity: 100,
                channel: event.channel))
        built.append(
            BuiltEvent(
                tick: event.tick + length, kind: .off, pitch: event.pitch, velocity: 64,
                channel: event.channel))
    }
    return MusicalMIDI1File(
        format: format, timebase: .init(ticksPerQuarterNote: UInt16(ticksPerBeat)),
        tracks: [track(from: built)])
}

private func swung(_ percent: Int, steps: Int = 16) -> MusicalMIDI1File {
    var events: [(tick: Int, pitch: Int, velocity: Int)] = []
    for step in 0..<steps {
        let delay =
            step % 2 == 0
            ? 0 : Arithmetic.pyRound(Double(ticksPerStep) * (2 * Double(percent) / 100 - 1))
        events.append((step * ticksPerStep + delay, 60, 100))
    }
    return songOf([events])
}

private func withTempo(_ midi: MusicalMIDI1File, bpm: Double) -> MusicalMIDI1File {
    var copy = midi
    var first = copy.tracks[0]
    first.events.insert(
        .init(
            delta: .none,
            event: .tempo(
                .musical(
                    MIDIFileEvent.MusicalTempo(
                        microsecondsPerQuarter: MIDIExport.bpmToMicroseconds(bpm))))),
        at: 0)
    copy.tracks[0] = first
    return copy
}

private struct Step: Equatable {
    let step: Int
    let pitch: Int
    let velocity: Int

    init(_ step: Int, _ pitch: Int, _ velocity: Int) {
        self.step = step
        self.pitch = pitch
        self.velocity = velocity
    }
}

private func stepsOf(_ result: ImportResult) -> [Step] {
    result.notes.map { Step($0.step, $0.pitch, $0.velocity) }
}

private func template() throws -> RawProject { try Samples.raw("Default.KeyStepPro") }

@Suite struct ImportRecipeTests {
    /// The note is half a step long because that is the gate a freshly placed one carries.
    @Test func oneNoteWritesExactlyTheM4Recipe() throws {
        let base = try Samples.raw("baseline.KeyStepPro")
        let result = try MIDIImport.convert(
            clipOf([(0, 60, 100)], length: ticksPerStep / 2), base, track: 2, pattern: 1)
        #expect(changedTo(base, result.raw) == placementRecipe)
    }

    @Test func aNonDefaultStepSizeWritesThePatternBitfield() throws {
        let base = try Samples.raw("baseline.KeyStepPro")
        let options = try ImportOptions(stepsPerBeat: 8)
        // Half a step at this grid, so the gate is the recipe's and only the bitfield differs.
        let result = try MIDIImport.convert(
            clipOf([(0, 60, 100)], length: ticksPerBeat / 8 / 2), base, track: 2, pattern: 1,
            options: options)

        let bits = Keys.key(124, Constants.pSeqPatternBits, 1)
        #expect(
            changedTo(base, result.raw) == placementRecipe.merging([bits: 28]) { _, new in new })
        #expect(Constants.stepDenominator(28) == 32)
    }

    @Test func theDefaultStepSizeLeavesTheBitfieldAlone() throws {
        let base = try Samples.raw("baseline.KeyStepPro")
        let result = try MIDIImport.convert(
            clipOf([(0, 60, 100)], length: ticksPerStep / 2), base, track: 2, pattern: 1)
        #expect(changedTo(base, result.raw) == placementRecipe)
    }

    @Test func conversionNeverAddsOrRemovesAKey() throws {
        let base = try template()
        let result = try MIDIImport.convert(
            clipOf([(0, 60, 100), (ticksPerStep, 64, 90)]), base)
        #expect(Set(result.raw.keys) == Set(base.keys))
    }

    @Test func conversionLeavesTheTemplateUntouched() throws {
        let base = try template()
        let before = base
        _ = try MIDIImport.convert(clipOf([(0, 60, 100)]), base)
        #expect(base == before)
    }
}

@Suite struct ReadClipTests {
    @Test func readClipPairsNoteOffs() throws {
        let clip = try MIDIImport.readClip(clipOf([(0, 60, 100), (240, 64, 90)]))
        #expect(clip.notes.map(\.tick) == [0, 240])
        #expect(clip.notes.map(\.durationTicks) == [120, 120])
        #expect(clip.notes.map(\.pitch) == [60, 64])
        #expect(clip.notes.map(\.velocity) == [100, 90])
    }

    @Test func readClipTreatsAZeroVelocityNoteOnAsANoteOff() throws {
        var only = MusicalMIDI1File.Track()
        only.events.append(.noteOn(note: 60, velocity: .midi1(100)))
        only.events.append(.noteOn(delta: .ticks(120), note: 60, velocity: .midi1(0)))
        let midi = MusicalMIDI1File(
            format: .singleTrack, timebase: .init(ticksPerQuarterNote: 480), tracks: [only])

        let clip = try MIDIImport.readClip(midi)
        #expect(clip.notes.map(\.pitch) == [60])
        #expect(clip.notes.map(\.durationTicks) == [120])
    }

    @Test func readClipClosesANoteTheFileNeverEnds() throws {
        var only = MusicalMIDI1File.Track()
        only.events.append(.noteOn(note: 60, velocity: .midi1(100)))
        only.events.append(.noteOn(delta: .ticks(240), note: 64, velocity: .midi1(100)))
        only.events.append(.noteOff(delta: .ticks(120), note: 64, velocity: .midi1(64)))
        let midi = MusicalMIDI1File(
            format: .singleTrack, timebase: .init(ticksPerQuarterNote: 480), tracks: [only])

        let clip = try MIDIImport.readClip(midi)
        let pairs = clip.notes.map { ($0.pitch, $0.durationTicks) }
            .stableSorted { ($0.0, $0.1) < ($1.0, $1.1) }
        #expect(pairs.map(\.0) == [60, 64])
        #expect(pairs.map(\.1) == [360, 120])
    }

    @Test func readClipTakesTheFilesTempo() throws {
        let midi = withTempo(clipOf([(0, 60, 100)]), bpm: 140)
        // The microsecond encoding rounds, so the round trip is not exact.
        #expect(abs(try MIDIImport.readClip(midi).tempoBPM - 140) < 0.01)
    }

    @Test func midiTracksSelectsOneTrack() throws {
        let midi = songOf([[(0, 60, 100)], [(0, 72, 100)]], length: 120)
        let second = try MIDIImport.readClip(midi, options: ImportOptions(midiTracks: [2]))

        #expect(second.notes.map(\.pitch) == [72])
        #expect(second.sourceTracks == [2])
    }

    @Test func anEmptySelectionReadsEveryTrack() throws {
        let midi = songOf([[(0, 60, 100)], [(0, 72, 100)]], length: 120)
        let both = try MIDIImport.readClip(midi, options: ImportOptions(midiTracks: []))

        #expect(both.notes.map(\.pitch) == [60, 72])
        #expect(both.sourceTracks == [1, 2])
    }

    @Test func aSelectedTrackTheFileLacksIsRefused() throws {
        let midi = songOf([[(0, 60, 100)], [(0, 72, 100)], [(0, 76, 100)]], length: 120)
        let thrown = #expect(throws: KSPError.self) {
            _ = try MIDIImport.readSong(midi, options: ImportOptions(midiTracks: [5]))
        }
        #expect(
            thrown?.description.contains("source track 5 was selected; the file has 3 tracks")
                == true)
    }

    /// One offender at a time, as the selection grammar itself reports.
    @Test func theLowestMissingSelectedTrackIsNamed() throws {
        let midi = songOf([[(0, 60, 100)], [(0, 72, 100)], [(0, 76, 100)]], length: 120)
        let thrown = #expect(throws: KSPError.self) {
            _ = try MIDIImport.readClip(midi, options: ImportOptions(midiTracks: [5, 9]))
        }
        #expect(thrown?.description.contains("source track 5 was selected") == true)
    }

    @Test func aNonContiguousSelectionArrivesInFileOrder() throws {
        let midi = songOf([60, 62, 64, 65, 67].map { [(0, $0, 100)] }, length: 120)
        let song = try MIDIImport.readSong(midi, options: ImportOptions(midiTracks: [5, 1, 2]))

        #expect(song.clips.map(\.sourceTracks) == [[1], [2], [5]])
        #expect(song.clips.map { $0.notes[0].pitch } == [60, 62, 67])
    }
}

@Suite struct QuantiseTests {
    @Test func notesLandOnTheirSteps() throws {
        let events = (0..<4).map { (tick: $0 * ticksPerStep, pitch: 60 + $0, velocity: 100) }
        let result = try MIDIImport.convert(clipOf(events), template())
        #expect(
            stepsOf(result) == [
                Step(1, 60, 100), Step(2, 61, 100), Step(3, 62, 100), Step(4, 63, 100),
            ])
    }

    @Test func stepsPerBeatChangesTheGrid() throws {
        let eighths = try MIDIImport.convert(
            clipOf([(0, 60, 100), (240, 64, 100)]), template(),
            options: ImportOptions(stepsPerBeat: 2))
        #expect(eighths.notes.map(\.step) == [1, 2])
    }

    @Test func anOffGridNoteIsMovedToTheNearestStep() throws {
        let result = try MIDIImport.convert(clipOf([(0, 60, 100), (130, 64, 100)]), template())
        #expect(result.notes.map(\.step) == [1, 2])
        #expect(result.diagnostics.entries.contains { $0.code == .notesQuantised })
    }

    @Test func aClipThatStartsLateIsAnchoredToStepOne() throws {
        let result = try MIDIImport.convert(
            clipOf([(1920, 60, 100), (2040, 64, 100)]), template())
        #expect(stepsOf(result) == [Step(1, 60, 100), Step(2, 64, 100)])
        #expect(result.diagnostics.entries.contains { $0.code == .clipAnchored })
    }

    @Test func aClipStartingAtZeroIsNotAnchored() throws {
        let result = try MIDIImport.convert(clipOf([(0, 60, 100)]), template())
        #expect(!result.diagnostics.entries.contains { $0.code == .clipAnchored })
    }

    @Test func simultaneousNotesAreAllKept() throws {
        let result = try MIDIImport.convert(
            clipOf([(0, 60, 100), (0, 67, 90), (0, 64, 80)]), template())
        let sorted = stepsOf(result).stableSorted { left, right in
            (left.step, left.pitch) < (right.step, right.pitch)
        }
        #expect(sorted == [Step(1, 60, 100), Step(1, 64, 80), Step(1, 67, 90)])
    }

    @Test func notesPastTheLastStepAreDropped() throws {
        let events = (0..<18).map { (tick: $0 * ticksPerStep, pitch: 60, velocity: 100) }
        let result = try MIDIImport.convert(clipOf(events), template())

        #expect(result.stepCount == 16)
        #expect(result.notes.map(\.step) == Array(1...16))
        let dropped = result.diagnostics.entries.filter { $0.code == .pastPatternEnd }
        #expect(dropped.map(\.subjects) == [2])
    }

    @Test func aNotesLengthBecomesItsGate() throws {
        var only = MusicalMIDI1File.Track()
        only.events.append(.noteOn(note: 60, velocity: .midi1(100)))
        only.events.append(
            .noteOff(delta: .ticks(UInt32(4 * ticksPerStep)), note: 60, velocity: .midi1(64)))
        only.events.append(.noteOn(note: 64, velocity: .midi1(100)))
        only.events.append(
            .noteOff(delta: .ticks(UInt32(ticksPerStep)), note: 64, velocity: .midi1(64)))
        let midi = MusicalMIDI1File(
            format: .singleTrack, timebase: .init(ticksPerQuarterNote: 480), tracks: [only])

        let result = try MIDIImport.convert(midi, template())
        #expect(result.notes.map { Constants.gateTable[$0.gate] } == [4.0, 1.0])
    }

    @Test func anEmptyClipWarnsAboutNothing() throws {
        let result = try MIDIImport.convert(clipOf([]), template())
        #expect(result.noteCount == 0)
        #expect(result.diagnostics.isEmpty)
    }

    @Test func notesFromTwoTracksAreReported() throws {
        let midi = songOf([[(0, 60, 100)], [(ticksPerStep, 72, 100)]], length: 120)
        let result = try MIDIImport.convert(midi, template())
        #expect(result.diagnostics.entries.contains { $0.code == .multipleSources })
    }

    @Test func quantiseRefusesAStepCountTheDeviceCannotHold() throws {
        let clip = try MIDIImport.readClip(clipOf([(0, 60, 100)]))
        let thrown = #expect(throws: KSPError.self) {
            try MIDIImport.quantise(clip, stepCount: Constants.maxSteps + 1)
        }
        #expect(thrown?.description.contains("out of range") == true)
    }

    @Test(arguments: [("stepsPerBeat", 0), ("midiTracks", 0), ("drumTrack", 0)])
    func optionsRefuseImpossibleValues(_ testCase: (String, Int)) {
        let (name, value) = testCase
        #expect(throws: KSPError.self) {
            switch name {
            case "stepsPerBeat": _ = try ImportOptions(stepsPerBeat: value)
            case "midiTracks": _ = try ImportOptions(midiTracks: [value])
            default: _ = try ImportOptions(drumTrack: .source(value))
            }
        }
    }

    @Test(
        arguments: [
            [TrackRoute(source: 0, device: 1)],
            [TrackRoute(source: 1, device: 0)],
            [TrackRoute(source: 1, device: 5)],
            [TrackRoute(source: 1, device: 2), TrackRoute(source: 1, device: 3)],
            [TrackRoute(source: 1, device: 2), TrackRoute(source: 2, device: 2)],
        ])
    func optionsRefuseImpossibleRoutes(_ routes: [TrackRoute]) {
        #expect(throws: KSPError.self) { _ = try ImportOptions(routes: routes) }
    }

    /// The message names the CLI flag, not the field, so it does not move.
    @Test func aSelectedTrackBelowOneIsNamedByTheOption() {
        let thrown = #expect(throws: KSPError.self) {
            _ = try ImportOptions(midiTracks: [1, 0])
        }
        #expect(thrown?.description == "midi_track counts from 1")
    }
}

@Suite struct ImportWriteTests {
    /// `48` is step-indexed while the pool is note-indexed: two notes two steps apart light 1 and 3.
    @Test func theStepActiveFlagIsIndexedByStep() throws {
        let result = try MIDIImport.convert(
            clipOf([(0, 60, 100), (2 * ticksPerStep, 64, 100)]), template(), track: 2)
        let flags = (1...4).map { intAt(result.raw, "124_48_1_1_\($0)") }
        #expect(flags == [1, 0, 1, 0])
    }

    @Test func aTrackInDrumOrArpModeIsRefused() throws {
        let base = try Samples.raw("initial_project.KeyStepPro")
        let thrown = #expect(throws: KSPError.self) {
            try MIDIImport.convert(clipOf([(0, 60, 100)]), base, track: 1)
        }
        #expect(thrown?.description.contains("86 bit 6") == true)
    }

    @Test func aPatternThatAlreadyHoldsNotesIsRefused() throws {
        let base = try Samples.raw("project_5.KeyStepPro")
        let thrown = #expect(throws: KSPError.self) {
            try MIDIImport.convert(clipOf([(0, 60, 100)]), base, track: 3, pattern: 1)
        }
        #expect(thrown?.description.contains("already holds notes") == true)
    }

    @Test func anEmptyPatternOfAUsedProjectIsAccepted() throws {
        let result = try MIDIImport.convert(
            clipOf([(0, 60, 100)]), Samples.raw("project_5.KeyStepPro"), track: 3, pattern: 2)
        #expect(stepsOf(result) == [Step(1, 60, 100)])
    }

    @Test(arguments: [0, 5])
    func trackMustBeOneOfTheDevicesFour(_ track: Int) throws {
        let base = try template()
        let thrown = #expect(throws: KSPError.self) {
            try MIDIImport.convert(clipOf([(0, 60, 100)]), base, track: track)
        }
        #expect(thrown?.description.contains("out of range") == true)
    }
}

@Suite struct CommittedClipTests {
    private func file(_ name: String) throws -> MusicalMIDI1File {
        try MusicalMIDI1File(
            data: Data(contentsOf: RepoData.projectFiles.appending(path: name)))
    }

    @Test func theSimpleClipBecomesSixteenSteps() throws {
        let result = try MIDIImport.convert(
            file("test_file_simple.mid"), template(), track: 1)
        #expect(
            stepsOf(result)
                == simplePitches.enumerated().map { Step($0.offset + 1, $0.element, 100) })
    }

    @Test func theChordClipKeepsEveryVoice() throws {
        let result = try MIDIImport.convert(file("test_file.mid"), template())
        #expect(result.notes.count == 26)
        let head = result.notes.prefix(6).map { ($0.step, $0.pitch) }
        #expect(head.map(\.0) == [1, 1, 1, 2, 2, 2])
        #expect(head.map(\.1) == [60, 64, 67, 60, 64, 67])
    }

    @Test func theSimpleClipRoundTripsThroughTheReader() throws {
        let result = try MIDIImport.convert(
            file("test_file_simple.mid"), template(), track: 1)
        let project = try Reader.readProject(result.raw, sourceName: "round-trip")
        let notes = project.track(1).pattern(1).notes(of: .seq)

        #expect(notes.map(\.step) == Array(1...16))
        #expect(notes.map(\.pitch) == simplePitches)
        #expect(notes.allSatisfy { $0.velocity == 100 })
        #expect(notes.allSatisfy { $0.active })
    }
}

@Suite struct SongPlanTests {
    @Test func eachSourceTrackGetsItsOwnDeviceTrack() throws {
        let midi = songOf([[(0, 60, 100)], [(0, 64, 100)], [(0, 67, 100)]])
        let result = try MIDIImport.convertSong(midi, template())
        #expect(result.plan.tracks.map(\.track) == [1, 2, 3])
        #expect(result.plan.tracks.map { $0.notes[0].pitch } == [60, 64, 67])
    }

    @Test func aFifthSourceTrackIsReportedRatherThanWritten() throws {
        let midi = songOf((0..<5).map { [(0, 60 + $0, 100)] })
        let result = try MIDIImport.convertSong(midi, template())
        #expect(result.plan.tracks.count == 4)
        let dropped = result.diagnostics.entries.filter { $0.code == .tracksDropped }
        #expect(dropped.map(\.subjects) == [1])
        #expect(
            dropped[0].detail
                == "1 source track(s) had nowhere to go; the device has 4 tracks")
    }

    @Test func aSelectionWiderThanTheDeviceIsReported() throws {
        let midi = songOf((0..<6).map { [(0, 60 + $0, 100)] })
        let options = try ImportOptions(midiTracks: [1, 2, 3, 4, 5])
        let result = try MIDIImport.convertSong(midi, template(), options: options)

        #expect(result.plan.tracks.count == 4)
        let dropped = result.diagnostics.entries.filter { $0.code == .tracksDropped }
        #expect(dropped.map(\.subjects) == [1])
        #expect(
            dropped[0].detail
                == "1 selected source track(s) had nowhere to go; the device has 4 tracks")
    }

    @Test func aTrackLongerThanOnePatternIsSplitAndChained() throws {
        let events = (0..<128).map { (tick: $0 * ticksPerStep, pitch: 60, velocity: 100) }
        let result = try MIDIImport.convertSong(songOf([events]), template())

        let plan = result.plan.tracks[0]
        #expect(plan.patterns == [1, 2])
        #expect(plan.placements.map(\.stepCount) == [64, 64])
        #expect(plan.placements.map { $0.notes.count } == [64, 64])
        // The second pattern restarts at step 1 rather than continuing to count.
        #expect(plan.placements[1].notes[0].step == 1)
        #expect(result.diagnostics.entries.contains { $0.code == .patternSplit })

        let project = try Reader.readProject(result.raw, sourceName: "split")
        #expect(project.scenes[0].chains[0].patterns == [1, 2])
    }

    /// `49` is step-indexed and lives wholly in chunk 1, like `48`, even for a note in chunk 2.
    @Test func aNotePastTheFirstPoolChunkStillPlaysOnEveryPass() throws {
        var events: [(tick: Int, pitch: Int, velocity: Int)] = []
        for step in 0..<32 {
            for voice in 0..<3 {
                events.append((step * ticksPerStep, 60 + voice, 100))
            }
        }
        let result = try MIDIImport.convertSong(songOf([events]), template())
        let project = try Reader.readProject(result.raw, sourceName: "spilled")

        let notes = project.track(1).pattern(1).notes(of: .seq)
        #expect(notes.count == 96)
        #expect(Set(notes.map(\.slot)) == [1, 2])
        #expect(notes.allSatisfy { $0.skip == Constants.skipSequences })
    }

    /// The automatic split is untouched, track by track.
    @Test func aTrackLongerThanTheDevicePlaysIsSplitAutomatically() throws {
        let events = (0..<96).map { (tick: $0 * ticksPerStep, pitch: 60, velocity: 100) }
        let result = try MIDIImport.convertSong(songOf([events, events]), template())

        #expect(result.plan.tracks[0].placements.map(\.stepCount) == [64, 32])
        #expect(result.plan.tracks[1].placements.map(\.stepCount) == [64, 32])
        #expect(result.diagnostics.entries.contains { $0.code == .patternSplit })
    }

    @Test func aTracksLengthRoundsUpToTheBar() throws {
        let events = [(0, 60, 100), (16 * ticksPerStep, 64, 100)]
        let result = try MIDIImport.convertSong(songOf([events]), template())
        #expect(result.plan.tracks[0].placements[0].stepCount == 32)
    }

    @Test func aDrumTrackIsWrittenToTrackOneInDrumMode() throws {
        let midi = songOf([[(0, 64, 100)], [(0, 36, 100), (ticksPerStep, 38, 100)]])
        let options = try ImportOptions(drumTrack: .source(2), drumMap: DrumMap.chromatic(36))
        let result = try MIDIImport.convertSong(midi, template(), options: options)

        let drum = try #require(result.plan.tracks.first { $0.isDrum })
        #expect(drum.track == 1)
        #expect(drum.notes.map(\.lane) == [0, 2])

        let project = try Reader.readProject(result.raw, sourceName: "drums")
        #expect(project.track(1).drumMode)
        let notes = project.track(1).pattern(1).notes(of: .drum)
        #expect(notes.map(\.step) == [1, 2])
        #expect(notes.map(\.pitch) == [0, 2])
        #expect(notes.allSatisfy { $0.active })
    }

    /// Channel index 9 is GM's reserved channel 10, so it needs no flag.
    @Test func aPercussionChannelTrackIsFoundWithoutBeingNamed() throws {
        let midi = songOf([[(0, 36, 100)]], channels: [9])
        let result = try MIDIImport.convertSong(midi, template())
        #expect(result.plan.tracks[0].isDrum)
    }

    /// A DAW parking a melodic patch on channel 10 is not writing a kit.
    @Test func noDrumsLeavesAPercussionTrackOnASequencerTrack() throws {
        let midi = songOf([[(0, 36, 100), (ticksPerStep, 38, 100)]], channels: [9])
        let options = try ImportOptions(drumTrack: .none)
        let result = try MIDIImport.convertSong(midi, template(), options: options)

        #expect(!result.plan.tracks.contains { $0.isDrum })
        #expect(result.notes.map(\.step) == [1, 2])
        #expect(result.notes.map(\.pitch) == [36, 38])

        let project = try Reader.readProject(result.raw, sourceName: "no drums")
        #expect(!project.track(1).drumMode)
    }

    /// Nothing was taken as drums, so there is no map to assume.
    @Test func noDrumsFitsNoDrumMap() throws {
        let midi = songOf([[(0, 36, 100)]], channels: [9])
        let options = try ImportOptions(drumTrack: .none)
        let result = try MIDIImport.convertSong(midi, template(), options: options)

        #expect(result.plan.drumMap == nil)
        #expect(!result.diagnostics.entries.contains { $0.code == .drumMapFitted })
    }

    @Test func theDefaultDesignationLooksForADrumTrack() throws {
        #expect(try ImportOptions().drumTrack == .auto)
    }

    @Test func aDrumPitchOutsideTheMapIsDroppedAndCounted() throws {
        let midi = songOf([[(0, 36, 100), (ticksPerStep, 120, 100)]])
        let options = try ImportOptions(drumTrack: .source(1), drumMap: DrumMap.chromatic(36))
        let result = try MIDIImport.convertSong(midi, template(), options: options)

        #expect(result.notes.map(\.lane) == [0])
        let unmapped = result.diagnostics.entries.filter { $0.code == .drumPitchUnmapped }
        #expect(unmapped.map(\.subjects) == [1])
    }

    @Test func anUnsetDrumMapIsFittedToTheSource() throws {
        let midi = songOf([[(0, 31, 100), (ticksPerStep, 34, 100)]])
        let result = try MIDIImport.convertSong(
            midi, template(), options: ImportOptions(drumTrack: .source(1)))

        let map = try #require(result.plan.drumMap)
        let lane0 = try map.noteForLane(0)
        #expect(lane0 == 31)
        #expect(result.notes.map(\.lane) == [0, 3])
        #expect(result.diagnostics.entries.contains { $0.code == .drumMapFitted })
    }

    /// A DAW that puts its kit anywhere but channel 10 still imports as drums.
    @Test func drumDetectionListensToTheNamedChannel() throws {
        let midi = songOf([[(0, 36, 100), (ticksPerStep, 38, 100)]], channels: [11])
        let options = try ImportOptions(drumChannel: 11, drumMap: DrumMap.chromatic(36))
        let result = try MIDIImport.convertSong(midi, template(), options: options)

        let drum = try #require(result.plan.tracks.first { $0.isDrum })
        #expect(drum.track == 1)
        #expect(drum.notes.map(\.lane) == [0, 2])
    }

    /// The search is exact: naming one channel does not widen it to any other.
    @Test func aTrackOffTheNamedChannelIsNotDrums() throws {
        let midi = songOf([[(0, 36, 100)]], channels: [11])
        let result = try MIDIImport.convertSong(midi, template())
        #expect(!result.plan.tracks.contains { $0.isDrum })
    }

    /// --drum-track names a track outright, so the channel is not searched at all.
    @Test func aNamedDrumTrackWinsOverTheDrumChannel() throws {
        let midi = songOf([[(0, 60, 100)], [(0, 36, 100)]], channels: [0, 11])
        let options = try ImportOptions(
            drumTrack: .source(1), drumChannel: 11, drumMap: DrumMap.chromatic(36))
        let result = try MIDIImport.convertSong(midi, template(), options: options)

        let drum = try #require(result.plan.tracks.first { $0.isDrum })
        #expect(drum.sourceTrack == 1)
    }

    /// The wording is the export option's, so the two directions read alike.
    @Test(arguments: [-1, 16]) func aDrumChannelOutsideTheRangeIsRefused(_ channel: Int) {
        let thrown = #expect(throws: KSPError.self) {
            _ = try ImportOptions(drumChannel: channel)
        }
        #expect(thrown?.description.contains("drum_channel must be 0-15") == true)
    }

    /// A miss is otherwise silent, so the hit has to say where it looked.
    @Test func theFittedMapNamesTheChannelItWasFoundOn() throws {
        let midi = songOf([[(0, 31, 100)]], channels: [11])
        let result = try MIDIImport.convertSong(
            midi, template(), options: ImportOptions(drumChannel: 11))

        let fitted = try #require(result.diagnostics.entries.first { $0.code == .drumMapFitted })
        #expect(fitted.detail.contains("found on channel 12"))
    }

    /// No channel was searched, so claiming one would be a lie.
    @Test func aNamedDrumTrackLeavesTheFittedMapNamingNoChannel() throws {
        let midi = songOf([[(0, 31, 100)]])
        let result = try MIDIImport.convertSong(
            midi, template(), options: ImportOptions(drumTrack: .source(1)))

        let fitted = try #require(result.diagnostics.entries.first { $0.code == .drumMapFitted })
        #expect(!fitted.detail.contains("found on channel"))
    }

    @Test func theSourceTempoIsWritten() throws {
        let midi = withTempo(songOf([[(0, 60, 100)]]), bpm: 96)
        let result = try MIDIImport.convertSong(midi, template())
        let tempo = try Reader.readProject(result.raw, sourceName: "tempo").tempoBPM
        #expect(tempo == 96.0)
    }

    @Test func theTemplateTempoIsKeptWhenAsked() throws {
        let base = try template()
        let midi = withTempo(songOf([[(0, 60, 100)]]), bpm: 96)
        let result = try MIDIImport.convertSong(
            midi, base, options: ImportOptions(carryTempo: false))

        let before = try Reader.readProject(base, sourceName: "before").tempoBPM
        let after = try Reader.readProject(result.raw, sourceName: "after").tempoBPM
        #expect(after == before)
    }

    @Test func aPatternOverThePoolCeilingIsReported() throws {
        var events: [(tick: Int, pitch: Int, velocity: Int)] = []
        for step in 0..<16 {
            for voice in 0..<13 {
                events.append((step * ticksPerStep, 60 + voice, 100))
            }
        }
        let result = try MIDIImport.convertSong(songOf([events]), template())
        #expect(result.notes.count == Constants.poolCapacity)
        let overflow = result.diagnostics.entries.filter { $0.code == .poolOverflow }
        #expect(overflow.map(\.subjects) == [16 * 13 - Constants.poolCapacity])
    }

    @Test func everyTargetPatternIsCheckedBeforeAnythingIsWritten() throws {
        let base = try template()
        let occupied = try MIDIImport.apply(
            base,
            plan: SongPlan(tracks: [
                TrackPlan(
                    track: 1,
                    placements: [
                        Placement(
                            notes: [PlacedNote(step: 1, pitch: 60, velocity: 100)],
                            stepCount: 16, pattern: 2)
                    ])
            ]))
        let events = (0..<128).map { (tick: $0 * ticksPerStep, pitch: 60, velocity: 100) }

        let thrown = #expect(throws: KSPError.self) {
            try MIDIImport.convertSong(songOf([events]), occupied)
        }
        #expect(thrown?.description.contains("already holds notes") == true)
    }
}

@Suite struct TimingFitTests {
    @Test(arguments: [50, 54, 58, 62, 66, 75])
    func aSwungClipComesBackAsTheSwingItWasMadeWith(_ percent: Int) throws {
        let result = try MIDIImport.convertSong(swung(percent), template())
        #expect(result.plan.tracks[0].placements[0].swingPercent == percent)
    }

    @Test(arguments: [50, 58, 66, 75])
    func swingSurvivesARoundTripThroughTheExporter(_ percent: Int) throws {
        let base = try template()
        let events = (0..<16).map { (tick: $0 * ticksPerStep, pitch: 60, velocity: 100) }
        let written = try MIDIImport.convertSong(songOf([events]), base)
        let swungProject = try Mutate.setSwing(
            written.raw, track: 1, pattern: 1, percent: percent)

        let exported = try MIDIExport.exportProject(
            Reader.readProject(swungProject, sourceName: "swung"))
        let back = try MIDIImport.convertSong(exported.midi, base)

        #expect(back.plan.tracks[0].placements[0].swingPercent == percent)
    }

    @Test func aFittedGrooveLeavesNothingForTimeShift() throws {
        let result = try MIDIImport.convertSong(swung(66), template())
        #expect(Set(result.notes.map(\.timeShift)) == [Constants.timeShiftCentre])
    }

    @Test func swingCanBeLeftAlone() throws {
        let result = try MIDIImport.convertSong(
            swung(66), template(), options: ImportOptions(fitSwing: false))
        #expect(result.plan.tracks[0].placements[0].swingPercent == 50)
        // With no swing to explain it, the groove goes to time shift instead.
        #expect(Set(result.notes.map(\.timeShift)) != [Constants.timeShiftCentre])
    }

    /// One unit is 1/400 of a beat -- 1.2 ticks at 480 PPQN, so 12 ticks is exactly 10 of them.
    @Test func anOffGridNoteWithinReachIsStoredAsATimeShift() throws {
        let midi = songOf([[(0, 60, 100), (2 * ticksPerStep + 12, 64, 100)]])
        let result = try MIDIImport.convertSong(midi, template())

        #expect(
            result.notes.map(\.timeShift)
                == [Constants.timeShiftCentre, Constants.timeShiftCentre + 10])
        #expect(!result.diagnostics.entries.contains { $0.code == .timingResidual })
    }

    /// The shift range is a fixed 60 ticks either way, not half a step, so at 1/4 most miss.
    @Test func aResidualPastTheShiftRangeIsReported() throws {
        let options = try ImportOptions(stepsPerBeat: 1, fitSwing: false)
        let midi = songOf(
            [[(0, 60, 100), (ticksPerBeat + 200, 64, 100)]], length: ticksPerBeat)
        let result = try MIDIImport.convertSong(midi, template(), options: options)

        #expect(result.notes.map(\.timeShift).max() == Constants.timeShiftStoredMax)
        #expect(result.diagnostics.entries.contains { $0.code == .timingResidual })
    }

    @Test func timeShiftCanBeTurnedOff() throws {
        let midi = songOf([[(0, 60, 100), (2 * ticksPerStep + 12, 64, 100)]])
        let result = try MIDIImport.convertSong(
            midi, template(), options: ImportOptions(fitTimeShift: false))
        #expect(Set(result.notes.map(\.timeShift)) == [Constants.timeShiftCentre])
    }
}

@Suite struct M6SongTests {
    private func m6() throws -> MusicalMIDI1File {
        try MusicalMIDI1File(
            data: Data(contentsOf: RepoData.projectFiles.appending(path: "m6-test-file.mid")))
    }

    private func converted() throws -> ImportResult {
        try MIDIImport.convertSong(
            m6(), Samples.raw("Default.KeyStepPro"), options: ImportOptions(drumTrack: .source(3)))
    }

    /// The acceptance file: four tracks, chords, tied notes and a split.
    @Test func theM6SongConvertsWhole() throws {
        let result = try converted()
        #expect(result.plan.tracks.map(\.track) == [1, 2, 3, 4])
        #expect(result.plan.tracks.map(\.isDrum) == [true, false, false, false])
        #expect(result.plan.tracks.map(\.patterns) == [[1], [1], [1], [1, 2]])
        #expect(
            result.plan.tracks.map { $0.placements.map { $0.notes.count } }
                == [[64], [160], [3], [32, 32]])
    }

    @Test func theM6SongRoundTripsThroughTheReader() throws {
        let result = try converted()
        // `saveable` injects the version key the factory template lacks and every saved one has.
        var restored: RawProject = [:]
        for (name, value) in MIDIImport.saveable(result.raw) {
            restored[name] = value
        }
        let project = try Reader.readProject(restored, sourceName: "m6")

        #expect(project.diagnostics.isEmpty)
        #expect(project.tempoBPM == 120.0)

        let drums = project.track(1).pattern(1)
        #expect(project.track(1).drumMode)
        #expect(drums.notes(of: .drum).count == 64)
        #expect(drums.drumStepCount == 64)
        #expect(Set(drums.notes(of: .drum).map(\.pitch)).sorted() == [0, 1, 2, 3])

        let chords = project.track(2).pattern(1)
        #expect(chords.seqStepCount == 48)
        #expect(chords.notes(of: .seq).count == 160)
        #expect(
            Set(chords.notes(of: .seq).filter { $0.step == 41 }.map(\.pitch)).sorted()
                == [60, 62, 64, 66])

        let held = project.track(3).pattern(1)
        #expect(held.seqStepCount == 32)
        #expect(held.notes(of: .seq).map(\.gate) == [8.0, 8.0, 16.0])

        #expect([1, 2].map { project.track(4).pattern($0).notes(of: .seq).count } == [32, 32])
        let chain = try #require(project.scenes[0].chains.first { $0.track == 4 })
        #expect(chain.patterns == [1, 2])
    }

    /// Existence is not audibility: a pooled note whose step-active bit is clear is silent.
    @Test func theM6SongIsAllAudible() throws {
        let result = try converted()
        let project = try Reader.readProject(result.raw, sourceName: "m6")

        let written = project.tracks.flatMap { $0.patterns.flatMap(\.notes) }
        #expect(written.count == result.noteCount)
        #expect(written.allSatisfy { $0.active })
    }

    @Test func theM6SongNeverAddsOrRemovesAKey() throws {
        let base = try Samples.raw("Default.KeyStepPro")
        let result = try converted()
        #expect(Set(result.raw.keys) == Set(base.keys))
    }
}

@Suite struct SourceShapeTests {
    /// The anchor belongs to the song, not the track, so a part that enters at bar 3 stays there.
    @Test func aTrackThatEntersLateKeepsItsPlaceAgainstTheOthers() throws {
        let bar = 16 * ticksPerStep
        let midi = songOf([[(0, 60, 100)], [(2 * bar, 72, 100)]])
        let result = try MIDIImport.convertSong(midi, template())

        #expect(result.plan.tracks[0].notes.map(\.step) == [1])
        #expect(result.plan.tracks[0].notes.map(\.pitch) == [60])
        #expect(result.plan.tracks[1].notes.map(\.step) == [33])
        #expect(result.plan.tracks[1].notes.map(\.pitch) == [72])
    }

    /// Past 64 steps the offset can only be kept by leaving patterns empty.
    @Test func aPartPastTheFirstPatternLandsInALaterOne() throws {
        let bar = 16 * ticksPerStep
        let midi = songOf([[(0, 60, 100)], [(5 * bar, 72, 100)]])
        let result = try MIDIImport.convertSong(midi, template())

        let second = result.plan.tracks[1]
        #expect(second.patterns == [1, 2])
        #expect(second.placements.map { $0.notes.count } == [0, 1])
        #expect(second.placements[1].notes[0].step == 17)
    }

    /// A short part looping under a long one is the sequencer working, not a drift to pad out.
    @Test func aShortTrackKeepsItsOwnLengthBesideALongOne() throws {
        let events = (0..<128).map { (tick: $0 * ticksPerStep, pitch: 60, velocity: 100) }
        let result = try MIDIImport.convertSong(songOf([events, [(0, 72, 100)]]), template())

        let longPart = result.plan.tracks[0]
        let shortPart = result.plan.tracks[1]
        #expect(longPart.patterns == [1, 2])
        #expect(longPart.placements.map(\.stepCount) == [64, 64])
        #expect(shortPart.patterns == [1])
        #expect(shortPart.placements.map(\.stepCount) == [16])
    }

    @Test func aTrackHoldingSeveralChannelsBecomesOneDeviceTrackEach() throws {
        let midi = mixedOf([(0, 60, 0), (0, 72, 1), (ticksPerStep, 62, 0)])
        let result = try MIDIImport.convertSong(midi, template())

        #expect(result.plan.tracks.map { $0.notes.map(\.pitch) } == [[60, 62], [72]])
        let split = result.diagnostics.entries.filter { $0.code == .trackSplitByChannel }
        #expect(split.map(\.subjects) == [2])
    }

    @Test func aSelectionStillSplitsAMixedTrackByChannel() throws {
        let midi = mixedOf([(0, 60, 0), (0, 72, 1)])
        let options = try ImportOptions(midiTracks: [1])
        let result = try MIDIImport.convertSong(midi, template(), options: options)

        #expect(result.plan.tracks.map { $0.notes.map(\.pitch) } == [[60], [72]])
        let split = result.diagnostics.entries.filter { $0.code == .trackSplitByChannel }
        #expect(split.map(\.subjects) == [2])

        // Channel 1 is not source track 2: the file has one track and the selection says so.
        let thrown = #expect(throws: KSPError.self) {
            _ = try MIDIImport.readSong(midi, options: ImportOptions(midiTracks: [2]))
        }
        #expect(
            thrown?.description.contains("source track 2 was selected; the file has 1 tracks")
                == true)
    }

    @Test func thePercussionChannelOfAMixedTrackIsStillFound() throws {
        let midi = mixedOf([(0, 60, 0), (0, 36, 9)])
        let result = try MIDIImport.convertSong(midi, template())

        let drum = try #require(result.plan.tracks.first { $0.isDrum })
        #expect(drum.track == 1)
        #expect(drum.notes.map(\.lane) == [0])
        #expect(!result.plan.tracks.contains { $0.isDrum && $0.track != 1 })
    }

    @Test func aNamedDrumTrackKeepsEveryChannelItHolds() throws {
        let midi = mixedOf([(0, 36, 0), (ticksPerStep, 38, 3)])
        let options = try ImportOptions(drumTrack: .source(1), drumMap: DrumMap.chromatic(36))
        let result = try MIDIImport.convertSong(midi, template(), options: options)

        #expect(result.plan.tracks.map(\.isDrum) == [true])
        #expect(result.notes.map(\.lane) == [0, 2])
    }

    @Test func moreNotesOnAStepThanTheFirmwareHoldsIsRefusedInPlanning() throws {
        let events = (0...Constants.maxNotesPerStep).map {
            (tick: 0, pitch: 40 + $0, velocity: 100)
        }
        let base = try template()
        let thrown = #expect(throws: KSPError.self) {
            try MIDIImport.convertSong(songOf([events]), base)
        }
        #expect(thrown?.description.contains("step 1") == true)
    }

    /// A timecode file decodes as `SMPTEMIDI1File`, so 0 is the only unusable timebase left.
    @Test func aFileWithNoTicksPerBeatIsRefused() throws {
        let midi = MusicalMIDI1File(
            format: .multipleTracksSynchronous, timebase: .init(ticksPerQuarterNote: 0),
            tracks: [MusicalMIDI1File.Track()])
        let thrown = #expect(throws: KSPError.self) { try MIDIImport.readSong(midi) }
        #expect(thrown?.description.contains("timecode") == true)
    }

    @Test func aTypeTwoFileIsRefused() throws {
        let midi = mixedOf([(0, 60, 0)], format: .multipleTracksAsynchronous)
        let thrown = #expect(throws: KSPError.self) { try MIDIImport.readSong(midi) }
        #expect(thrown?.description.contains("type 2") == true)
    }

    @Test(arguments: [(20.0, 30.0), (300.0, 240.0), (30.0, 30.0), (240.0, 240.0)])
    func aTempoTheDeviceCannotRunIsHeldToItsRange(_ testCase: (Double, Double)) throws {
        let (source, written) = testCase
        let midi = withTempo(songOf([[(0, 60, 100)]]), bpm: source)
        let result = try MIDIImport.convertSong(midi, template())

        let played = try Reader.readProject(result.raw, sourceName: "tempo").tempoBPM
        #expect(played == written)
        let held = result.diagnostics.entries.contains { $0.code == .tempoOutOfRange }
        #expect(held == (source != written))
    }

    @Test func eventsTheDeviceCannotStoreAreReported() throws {
        var midi = songOf([[(0, 60, 100)]])
        var first = midi.tracks[0]
        first.events.insert(.cc(controller: 7, value: .midi1(100), channel: 0), at: 0)
        first.events.insert(.pitchBend(value: .midi1(2000), channel: 0), at: 0)
        midi.tracks[0] = first

        let result = try MIDIImport.convertSong(midi, template())
        let dropped = result.diagnostics.entries.filter { $0.code == .controllersDropped }
        #expect(dropped.map(\.subjects) == [2])
    }
}

@Suite struct TrackRouteTests {
    /// Each plan's device track beside the source track it came from.
    private func routed(_ result: ImportResult) -> [[Int?]] {
        result.plan.tracks.map { [$0.track, $0.sourceTrack] }
    }

    @Test func aRoutePutsASourceTrackWhereItSays() throws {
        let midi = songOf([[(0, 60, 100)], [(0, 64, 100)], [(0, 67, 100)]])
        let options = try ImportOptions(
            routes: [TrackRoute(source: 3, device: 1), TrackRoute(source: 1, device: 2)])
        let result = try MIDIImport.convertSong(midi, template(), options: options)

        #expect(routed(result) == [[1, 3], [2, 1], [3, 2]])
        #expect(result.plan.tracks.map { $0.notes[0].pitch } == [67, 60, 64])
    }

    @Test func unroutedTracksFillTheDeviceTracksARouteLeft() throws {
        let midi = songOf([[(0, 60, 100)], [(0, 64, 100)], [(0, 67, 100)]])
        let options = try ImportOptions(routes: [TrackRoute(source: 1, device: 3)])
        let result = try MIDIImport.convertSong(midi, template(), options: options)

        #expect(routed(result) == [[1, 2], [2, 3], [3, 1]])
    }

    @Test func withoutRoutesAssignmentIsUnchanged() throws {
        let midi = songOf(
            [[(0, 60, 100)], [(0, 36, 100)], [(0, 67, 100)]], channels: [0, 9, 0])
        let result = try MIDIImport.convertSong(midi, template())

        #expect(routed(result) == [[1, 2], [2, 1], [3, 3]])
        #expect(result.plan.tracks.map(\.isDrum) == [true, false, false])
    }

    @Test func aRouteMayNotSendTheDrumTrackOffDeviceTrackOne() {
        let thrown = #expect(throws: KSPError.self) {
            _ = try ImportOptions(drumTrack: .source(2), routes: [TrackRoute(source: 2, device: 3)])
        }
        #expect(
            thrown?.description.contains("route 2:3 sends the drum track to device track 3")
                == true)
    }

    @Test func aRouteMayNotTakeDeviceTrackOneFromTheDrums() throws {
        let midi = songOf([[(0, 36, 100)], [(0, 60, 100)]], channels: [9, 0])
        let options = try ImportOptions(routes: [TrackRoute(source: 2, device: 1)])
        let thrown = #expect(throws: KSPError.self) {
            _ = try MIDIImport.convertSong(midi, template(), options: options)
        }
        #expect(
            thrown?.description.contains("route 2:1 collides with the drum track") == true)
    }

    @Test func aRouteMayNotSendAnAutoDetectedDrumTrackElsewhere() throws {
        let midi = songOf([[(0, 36, 100)], [(0, 60, 100)]], channels: [9, 0])
        let options = try ImportOptions(routes: [TrackRoute(source: 1, device: 2)])
        let thrown = #expect(throws: KSPError.self) {
            _ = try MIDIImport.convertSong(midi, template(), options: options)
        }
        #expect(
            thrown?.description.contains("route 1:2 sends the drum track to device track 2")
                == true)
    }

    @Test func routingTheDrumTrackToDeviceTrackOneIsAllowed() throws {
        let midi = songOf([[(0, 60, 100)], [(0, 36, 100)]])
        let options = try ImportOptions(
            drumTrack: .source(2), drumMap: DrumMap.chromatic(36),
            routes: [TrackRoute(source: 2, device: 1)])
        let result = try MIDIImport.convertSong(midi, template(), options: options)

        #expect(routed(result) == [[1, 2], [2, 1]])
        #expect(result.plan.tracks.map(\.isDrum) == [true, false])
    }

    /// Track 1 is an ordinary target once nothing claims it as a drum set.
    @Test func noDrumsLetsARouteTakeDeviceTrackOne() throws {
        let midi = songOf([[(0, 60, 100)], [(0, 36, 100)]], channels: [0, 9])
        let options = try ImportOptions(
            drumTrack: .none, routes: [TrackRoute(source: 2, device: 1)])
        let result = try MIDIImport.convertSong(midi, template(), options: options)

        #expect(routed(result) == [[1, 2], [2, 1]])
        #expect(!result.plan.tracks.contains { $0.isDrum })
    }

    @Test func aRouteOntoDeviceTrackOneIsRefusedBesideANamedDrumTrack() {
        let thrown = #expect(throws: KSPError.self) {
            _ = try ImportOptions(drumTrack: .source(2), routes: [TrackRoute(source: 3, device: 1)])
        }
        #expect(thrown?.description.contains("route 3:1 collides with the drum track") == true)
    }

    @Test func aRouteIsHonouredBelowTheStartingTrack() throws {
        let midi = songOf([[(0, 60, 100)], [(0, 64, 100)]])
        let options = try ImportOptions(routes: [TrackRoute(source: 1, device: 1)])
        let song = try MIDIImport.readSong(midi, options: options)
        let plan = try MIDIImport.planSong(song, options: options, firstTrack: 3)

        #expect(plan.tracks.map { [$0.track, $0.sourceTrack] } == [[1, 1], [3, 2]])
    }

    /// Otherwise assign reports it as holding no notes, which sends the user to fix the file.
    @Test func aDrumTrackOutsideTheSelectionIsRefused() {
        let thrown = #expect(throws: KSPError.self) {
            _ = try ImportOptions(midiTracks: [2, 3], drumTrack: .source(5))
        }
        #expect(thrown?.description.contains("drum_track 5 is not in the selection") == true)
    }

    @Test func aDrumTrackInsideTheSelectionIsAllowed() throws {
        #expect(
            try ImportOptions(midiTracks: [2, 5], drumTrack: .source(5)).drumTrack == .source(5))
    }

    @Test func aRouteInsideTheSelectionIsAllowed() throws {
        let options = try ImportOptions(
            midiTracks: [1, 3], routes: [TrackRoute(source: 3, device: 1)])

        #expect(options.routes == [TrackRoute(source: 3, device: 1)])
    }

    @Test func aRouteOutsideTheSelectionIsRefused() {
        let thrown = #expect(throws: KSPError.self) {
            _ = try ImportOptions(midiTracks: [1, 3], routes: [TrackRoute(source: 2, device: 1)])
        }
        #expect(
            thrown?.description.contains(
                "route 2:1 names source track 2, which is not in the selection") == true)
    }

    @Test func twoSourcesOnOneDeviceTrackAreRefused() {
        let thrown = #expect(throws: KSPError.self) {
            _ = try ImportOptions(
                routes: [TrackRoute(source: 1, device: 2), TrackRoute(source: 3, device: 2)])
        }
        #expect(
            thrown?.description.contains("routes 1:2 and 3:2 both name device track 2") == true)
    }

    @Test(arguments: [0, 5])
    func aRouteOutsideTheDevicesFourTracksIsRefused(_ device: Int) {
        let thrown = #expect(throws: KSPError.self) {
            _ = try ImportOptions(routes: [TrackRoute(source: 1, device: device)])
        }
        #expect(
            thrown?.description.contains("names device track \(device); the device has 4 tracks")
                == true)
    }

    @Test func aRouteNamingATrackWithNoNotesIsRefused() throws {
        let midi = songOf([[(0, 60, 100)], [(0, 64, 100)]])
        let options = try ImportOptions(routes: [TrackRoute(source: 3, device: 1)])
        let thrown = #expect(throws: KSPError.self) {
            _ = try MIDIImport.convertSong(midi, template(), options: options)
        }
        #expect(thrown?.description.contains("track 3 of the source holds no notes") == true)
    }

    @Test func aRoutedTrackSplitAcrossChannelsIsMerged() throws {
        let midi = mixedOf([(0, 60, 0), (0, 72, 1), (ticksPerStep, 62, 0)])
        let options = try ImportOptions(routes: [TrackRoute(source: 1, device: 2)])
        let result = try MIDIImport.convertSong(midi, template(), options: options)

        #expect(routed(result) == [[2, 1]])
        #expect(result.notes.map(\.pitch) == [60, 72, 62])
    }

    @Test func routesDoNotChangeTheDroppedTrackReport() throws {
        let midi = songOf((0..<5).map { [(0, 60 + $0, 100)] })
        let options = try ImportOptions(routes: [TrackRoute(source: 5, device: 1)])
        let result = try MIDIImport.convertSong(midi, template(), options: options)

        #expect(routed(result) == [[1, 5], [2, 1], [3, 2], [4, 3]])
        let dropped = result.diagnostics.entries.filter { $0.code == .tracksDropped }
        #expect(dropped.map(\.subjects) == [1])
    }
}

private func sourceOf(
    _ name: String, _ tracks: [[(tick: Int, pitch: Int, velocity: Int)]],
    ticksPerQuarterNote: Int = ticksPerBeat, length: Int = ticksPerStep
) -> Source {
    var built: [MusicalMIDI1File.Track] = []
    for events in tracks {
        var timed: [BuiltEvent] = []
        for event in events {
            timed.append(
                BuiltEvent(
                    tick: event.tick, kind: .on, pitch: event.pitch, velocity: event.velocity,
                    channel: 0))
            timed.append(
                BuiltEvent(
                    tick: event.tick + length, kind: .off, pitch: event.pitch, velocity: 64,
                    channel: 0))
        }
        built.append(track(from: timed))
    }
    return Source(
        name,
        MusicalMIDI1File(
            format: .multipleTracksSynchronous,
            timebase: .init(ticksPerQuarterNote: UInt16(ticksPerQuarterNote)), tracks: built))
}

private func withSignature(_ source: Source, _ numerator: Int, _ denominator: Int)
    -> Source
{
    var copy = source.midi
    var first = copy.tracks[0]
    first.events.insert(
        .timeSignature(numerator: UInt8(numerator), denominator: UInt8(denominator)), at: 0)
    copy.tracks[0] = first
    return Source(source.name, copy)
}

private func withTempo(_ source: Source, bpm: Double) -> Source {
    Source(source.name, withTempo(source.midi, bpm: bpm))
}

/// A second tempo one beat in, so the file's *first* tempo is left where it was.
private func thenTempo(_ source: Source, bpm: Double, at tick: Int) -> Source {
    var copy = source.midi
    var first = copy.tracks[0]
    first.events.append(
        .init(
            delta: .ticks(UInt32(tick)),
            event: .tempo(
                .musical(
                    MIDIFileEvent.MusicalTempo(
                        microsecondsPerQuarter: MIDIExport.bpmToMicroseconds(bpm))))))
    copy.tracks[0] = first
    return Source(source.name, copy)
}

private func codes(_ result: ImportResult) -> Set<Code> {
    Set(result.diagnostics.entries.map(\.code))
}

@Suite struct MultiFileTests {
    @Test func twoFilesBecomeOneSong() throws {
        let first = sourceOf("a.mid", [[(0, 60, 100)], [(0, 64, 100)]])
        let second = sourceOf("b.mid", [[(0, 67, 100)]])

        let song = try MIDIImport.readSongs([first, second])

        #expect(song.clips.map { $0.notes[0].pitch } == [60, 64, 67])
    }

    @Test func everyClipRecordsTheFileItCameFrom() throws {
        let first = sourceOf("a.mid", [[(0, 60, 100)], [(0, 64, 100)]])
        let second = sourceOf("b.mid", [[(0, 67, 100)]])

        let song = try MIDIImport.readSongs([first, second])

        #expect(song.clips.map(\.sourceFile) == ["a.mid", "a.mid", "b.mid"])
    }

    /// One numbering across the run, so --route and --midi-tracks still address a track.
    @Test func sourceTracksNumberOnThroughTheFiles() throws {
        let first = sourceOf("a.mid", [[(0, 60, 100)], [(0, 64, 100)]])
        let second = sourceOf("b.mid", [[(0, 67, 100)], [(0, 71, 100)]])

        let song = try MIDIImport.readSongs([first, second])

        #expect(song.clips.map(\.sourceTracks) == [[1], [2], [3], [4]])
    }

    @Test func aSelectionReachesIntoTheSecondFile() throws {
        let first = sourceOf("a.mid", [[(0, 60, 100)], [(0, 64, 100)]])
        let second = sourceOf("b.mid", [[(0, 67, 100)], [(0, 71, 100)]])

        let song = try MIDIImport.readSongs(
            [first, second], options: ImportOptions(midiTracks: [3]))

        #expect(song.clips.map { $0.notes[0].pitch } == [67])
        #expect(song.clips.map(\.sourceFile) == ["b.mid"])
    }

    @Test func aSelectionPastEveryFileIsRefusedNamingTheTotal() throws {
        let first = sourceOf("a.mid", [[(0, 60, 100)], [(0, 64, 100)]])
        let second = sourceOf("b.mid", [[(0, 67, 100)]])
        let thrown = #expect(throws: KSPError.self) {
            _ = try MIDIImport.readSongs(
                [first, second], options: ImportOptions(midiTracks: [4]))
        }

        #expect(
            thrown?.description.contains("source track 4 was selected; the 2 files hold 3")
                == true)
    }

    /// One beat is one beat: 96 ticks at 96 PPQ has to land on 480 at 480 PPQ.
    @Test func aLaterFileAtAnotherResolutionIsRescaledOntoTheFirsts() throws {
        let first = sourceOf("a.mid", [[(0, 60, 100)]])
        let second = sourceOf("b.mid", [[(96, 67, 100)]], ticksPerQuarterNote: 96, length: 24)

        let song = try MIDIImport.readSongs([first, second])

        #expect(song.ticksPerBeat == ticksPerBeat)
        #expect(song.clips.map { $0.notes[0].tick } == [0, ticksPerBeat])
        #expect(song.resolutionConflicts == 1)
    }

    /// Rounding a sub-tick note to nothing would silently delete it.
    @Test func rescalingDownLeavesAShortNoteATickLong() throws {
        let first = sourceOf("a.mid", [[(0, 60, 100)]], ticksPerQuarterNote: 96, length: 24)
        let second = sourceOf("b.mid", [[(0, 67, 100)]], length: 1)

        let song = try MIDIImport.readSongs([first, second])

        #expect(song.clips[1].notes[0].durationTicks == 1)
    }

    @Test func aLaterFilesResolutionIsReported() throws {
        let first = sourceOf("a.mid", [[(0, 60, 100)]])
        let second = sourceOf("b.mid", [[(0, 67, 100)]], ticksPerQuarterNote: 96, length: 24)

        let result = try MIDIImport.convertSongs([first, second], try template())

        #expect(codes(result).contains(.sourceResolutionDiffers))
    }

    @Test func theFirstFilesTempoIsWrittenAndTheDisagreementReported() throws {
        let first = withTempo(sourceOf("a.mid", [[(0, 60, 100)]]), bpm: 140)
        let second = withTempo(sourceOf("b.mid", [[(0, 67, 100)]]), bpm: 90)

        let result = try MIDIImport.convertSongs([first, second], try template())

        #expect(abs((result.plan.tempoBPM ?? 0) - 140) < 0.01)
        #expect(codes(result).contains(.sourceTempoDiffers))
    }

    /// Nothing was overridden if nothing was written.
    @Test func aTempoDisagreementIsSilentWhenNoTempoIsCarried() throws {
        let first = withTempo(sourceOf("a.mid", [[(0, 60, 100)]]), bpm: 140)
        let second = withTempo(sourceOf("b.mid", [[(0, 67, 100)]]), bpm: 90)
        let options = try ImportOptions(carryTempo: false)

        let result = try MIDIImport.convertSongs([first, second], try template(), options: options)

        #expect(!codes(result).contains(.sourceTempoDiffers))
    }

    @Test func theFirstFilesMeterSetsTheBarAndTheDisagreementIsReported() throws {
        let first = withSignature(sourceOf("a.mid", [[(0, 60, 100)]]), 4, 2)
        let second = withSignature(sourceOf("b.mid", [[(0, 67, 100)]]), 3, 2)

        let song = try MIDIImport.readSongs([first, second])
        let result = try MIDIImport.convertSongs([first, second], try template())

        #expect(song.beatsPerBar == 4)
        #expect(song.meterConflicts == 1)
        #expect(codes(result).contains(.sourceMeterDiffers))
    }

    @Test func agreeingFilesReportNothing() throws {
        let first = sourceOf("a.mid", [[(0, 60, 100)]])
        let second = sourceOf("b.mid", [[(0, 67, 100)]])

        let raised = codes(try MIDIImport.convertSongs([first, second], try template()))

        #expect(!raised.contains(.sourceTempoDiffers))
        #expect(!raised.contains(.sourceResolutionDiffers))
        #expect(!raised.contains(.sourceMeterDiffers))
    }

    @Test func aDeviceTrackRecordsTheFileItCameFrom() throws {
        let first = sourceOf("a.mid", [[(0, 60, 100)]])
        let second = sourceOf("b.mid", [[(0, 67, 100)]])

        let result = try MIDIImport.convertSongs([first, second], try template())

        #expect(result.plan.tracks.map(\.sourceFile) == ["a.mid", "b.mid"])
    }

    @Test func oneSourceReadsExactlyAsASingleFileDoes() throws {
        let midi = songOf([[(0, 60, 100)], [(ticksPerStep, 64, 100)]])

        let together = try MIDIImport.readSongs([Source("", midi)])

        #expect(together == (try MIDIImport.readSong(midi)))
    }

    @Test func oneSourceConvertsExactlyAsASingleFileDoes() throws {
        let midi = songOf([[(0, 60, 100)], [(ticksPerStep, 64, 100)]])

        let together = try MIDIImport.convertSongs(
            [Source("", midi)], try template())
        let alone = try MIDIImport.convertSong(midi, try template())

        #expect(changedTo(try template(), together.raw) == changedTo(try template(), alone.raw))
    }

    /// Counting the run's tempo events rather than one file's would claim a change.
    @Test func twoConstantTempoFilesAreNotAtempoChange() throws {
        let first = withTempo(sourceOf("a.mid", [[(0, 60, 100)]]), bpm: 120)
        let second = withTempo(sourceOf("b.mid", [[(0, 67, 100)]]), bpm: 120)

        let result = try MIDIImport.convertSongs([first, second], try template())

        #expect(!codes(result).contains(.tempoChangesIgnored))
    }

    @Test func afileThatReallyChangesTempoIsStillReported() throws {
        let first = thenTempo(
            withTempo(sourceOf("a.mid", [[(0, 60, 100)]]), bpm: 120), bpm: 90, at: 480)
        let second = withTempo(sourceOf("b.mid", [[(0, 67, 100)]]), bpm: 120)

        let result = try MIDIImport.convertSongs([first, second], try template())

        // The files agree on their opening tempo; only the change within one of them is news.
        #expect(codes(result).contains(.tempoChangesIgnored))
        #expect(!codes(result).contains(.sourceTempoDiffers))
    }

    /// It supplied no note to rescale, so there is nothing to have overridden.
    @Test func awhollyDeselectedFileReportsNoDisagreement() throws {
        let first = withTempo(sourceOf("a.mid", [[(0, 60, 100)]]), bpm: 120)
        let second = withTempo(
            sourceOf("b.mid", [[(0, 67, 100)]], ticksPerQuarterNote: 96, length: 24), bpm: 90)
        let options = try ImportOptions(midiTracks: [1])

        let song = try MIDIImport.readSongs([first, second], options: options)
        let result = try MIDIImport.convertSongs(
            [first, second], try template(), options: options)

        #expect(song.clips.map(\.sourceFile) == ["a.mid"])
        #expect(song.tempoConflicts == 0)
        #expect(song.resolutionConflicts == 0)
        #expect(!codes(result).contains(.sourceTempoDiffers))
        #expect(!codes(result).contains(.sourceResolutionDiffers))
    }

    /// Otherwise the same file would gate differently for the company it keeps.
    @Test func azeroLengthNoteStaysZeroLengthThroughArescale() throws {
        let first = sourceOf("a.mid", [[(0, 60, 100)]], ticksPerQuarterNote: 96, length: 24)
        let second = sourceOf("b.mid", [[(0, 67, 100)]], length: 0)

        let alone = try MIDIImport.readSongs([second])
        let rescaled = try MIDIImport.readSongs([first, second])

        #expect(alone.clips[0].notes[0].durationTicks == 0)
        #expect(rescaled.clips[1].notes[0].durationTicks == 0)
    }

    @Test func noSourceAtAllIsRefused() throws {
        let thrown = #expect(throws: KSPError.self) {
            _ = try MIDIImport.readSongs([])
        }

        #expect(thrown?.description.contains("no source file was given") == true)
    }
}

@Suite struct FlatVelocityImportTests {
    @Test(arguments: [1, 127])
    func theBoundsAreAccepted(velocity: Int) throws {
        #expect(try ImportOptions(flatVelocity: velocity).flatVelocity == velocity)
    }

    @Test(arguments: [0, 128])
    func aVelocityOutsideTheRangeIsRefused(velocity: Int) {
        let thrown = #expect(throws: KSPError.self) {
            _ = try ImportOptions(flatVelocity: velocity)
        }
        #expect(
            thrown?.description
                == "flat_velocity must be 1-127; 0 is a MIDI note-off, not a silent note")
    }

    @Test func aFlatVelocityReplacesEveryWrittenVelocity() throws {
        let events = [(0, 60, 20), (ticksPerStep, 62, 90), (ticksPerStep * 2, 64, 127)]
        let result = try MIDIImport.convert(
            clipOf(events), template(), options: ImportOptions(flatVelocity: 64))

        #expect(result.notes.map(\.velocity) == [64, 64, 64])
    }

    @Test func anUnsetFlatVelocityKeepsTheSourceVelocities() throws {
        let events = [(0, 60, 20), (ticksPerStep, 62, 90), (ticksPerStep * 2, 64, 127)]
        let result = try MIDIImport.convert(clipOf(events), template())

        #expect(result.notes.map(\.velocity) == [20, 90, 127])
    }

    /// Drums are written through a different `Mutate` call, off the same `PlacedNote`.
    @Test func aFlatVelocityReachesDrumTriggers() throws {
        let midi = songOf([[(0, 36, 20), (ticksPerStep, 37, 90)]])
        let options = try ImportOptions(
            drumTrack: .source(1), drumMap: DrumMap.chromatic(36),
            flatVelocity: MIDIExport.defaultFlatVelocity)
        let result = try MIDIImport.convertSong(midi, template(), options: options)

        #expect(result.notes.map(\.lane) == [0, 1])
        #expect(
            result.notes.map(\.velocity)
                == [MIDIExport.defaultFlatVelocity, MIDIExport.defaultFlatVelocity])
    }
}
