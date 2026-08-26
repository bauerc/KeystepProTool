import Foundation
import KSPKit
import SwiftMIDIFile

public enum MIDIExport {
    /// Divides by 3 and 4, so every step size stays exact; the finest is a 1/32 triplet.
    public static let defaultTicksPerBeat = 480

    public static let ticksPerBeatDivisor = 24

    /// The device's Drum output default is channel 10 counting from 1; MIDI counts from 0.
    public static let drumChannel = DrumMap.defaultDrumChannel - 1

    /// A note stored with velocity 0 is silent on the device but reads as a note-off in MIDI.
    public static let minVelocity = 1

    public static let maxVelocity = 127

    public static let defaultFlatVelocity = Constants.freshVelocity

    public static let maxRepeat = 10

    /// Shared by both directions; `nil` means "leave every velocity alone".
    public static func checkFlatVelocity(_ velocity: Int?) throws {
        if let velocity, !(MIDIExport.minVelocity...MIDIExport.maxVelocity ~= velocity) {
            throw KSPError.value(
                "flat_velocity must be \(MIDIExport.minVelocity)-\(MIDIExport.maxVelocity); "
                    + "0 is a MIDI note-off, not a silent note")
        }
    }
}

public struct ExportOptions: Sendable, Hashable {
    public let ticksPerBeat: Int
    public let drumMap: DrumMap
    public let drumChannel: Int

    public let defaultGate: Double

    public let applySwing: Bool

    public let applyTimeShift: Bool

    public let includeStale: Bool

    public let includeDisabled: Bool

    public let markers: Bool

    public let passes: Int?

    public let flatVelocity: Int?

    public let repeatCount: Int

    public init(
        ticksPerBeat: Int = MIDIExport.defaultTicksPerBeat,
        drumMap: DrumMap? = nil,
        drumChannel: Int = MIDIExport.drumChannel,
        defaultGate: Double = Constants.defaultGateLength,
        applySwing: Bool = true,
        applyTimeShift: Bool = true,
        includeStale: Bool = false,
        includeDisabled: Bool = false,
        markers: Bool = true,
        passes: Int? = nil,
        flatVelocity: Int? = nil,
        repeatCount: Int = 1
    ) throws {
        if ticksPerBeat < 1 {
            throw KSPError.value("ticks_per_beat must be at least 1")
        }
        if ticksPerBeat % MIDIExport.ticksPerBeatDivisor != 0 {
            throw KSPError.value(
                "ticks_per_beat \(ticksPerBeat) is not divisible by "
                    + "\(MIDIExport.ticksPerBeatDivisor); the device's 1/4-1/32 step sizes and "
                    + "their triplets would not land on exact ticks")
        }
        if !(0...15 ~= drumChannel) {
            throw KSPError.value("drum_channel must be 0-15")
        }
        if defaultGate <= 0 {
            throw KSPError.value("default_gate must be greater than 0")
        }
        if let passes, !(1...Constants.skipCyclePasses ~= passes) {
            throw KSPError.value(
                "passes must be 1-\(Constants.skipCyclePasses), or None for auto")
        }
        try MIDIExport.checkFlatVelocity(flatVelocity)
        if !(1...MIDIExport.maxRepeat ~= repeatCount) {
            throw KSPError.value("repeat must be 1-\(MIDIExport.maxRepeat)")
        }
        self.ticksPerBeat = ticksPerBeat
        self.drumMap = try drumMap ?? DrumMap.chromatic()
        self.drumChannel = drumChannel
        self.defaultGate = defaultGate
        self.applySwing = applySwing
        self.applyTimeShift = applyTimeShift
        self.includeStale = includeStale
        self.includeDisabled = includeDisabled
        self.markers = markers
        self.passes = passes
        self.flatVelocity = flatVelocity
        self.repeatCount = repeatCount
    }

    func with(passes: Int?) throws -> ExportOptions {
        try ExportOptions(
            ticksPerBeat: ticksPerBeat, drumMap: drumMap, drumChannel: drumChannel,
            defaultGate: defaultGate, applySwing: applySwing, applyTimeShift: applyTimeShift,
            includeStale: includeStale, includeDisabled: includeDisabled, markers: markers,
            passes: passes, flatVelocity: flatVelocity, repeatCount: repeatCount)
    }
}

public struct RenderedNote: Sendable, Hashable {
    public let tick: Int
    public let durationTicks: Int
    public let pitch: Int
    public let velocity: Int
    public let channel: Int

    public init(tick: Int, durationTicks: Int, pitch: Int, velocity: Int, channel: Int) {
        self.tick = tick
        self.durationTicks = durationTicks
        self.pitch = pitch
        self.velocity = velocity
        self.channel = channel
    }

    func with(tick: Int) -> RenderedNote {
        RenderedNote(
            tick: tick, durationTicks: durationTicks, pitch: pitch, velocity: velocity,
            channel: channel)
    }

    func with(durationTicks: Int) -> RenderedNote {
        RenderedNote(
            tick: tick, durationTicks: durationTicks, pitch: pitch, velocity: velocity,
            channel: channel)
    }
}

public struct Rendering: Sendable, Hashable {
    public let trackNumber: Int
    public let kind: NoteKind
    public let patternNumber: Int
    public let notes: [RenderedNote]
    public let lengthTicks: Int
    public let diagnostics: Report

    public init(
        trackNumber: Int, kind: NoteKind, patternNumber: Int, notes: [RenderedNote],
        lengthTicks: Int, diagnostics: Report = Report()
    ) {
        self.trackNumber = trackNumber
        self.kind = kind
        self.patternNumber = patternNumber
        self.notes = notes
        self.lengthTicks = lengthTicks
        self.diagnostics = diagnostics
    }

    public var warnings: [String] { diagnostics.messages }

    public var midiTrackName: String { Rendering.trackName(trackNumber, kind: kind) }

    public static func trackName(_ trackNumber: Int, kind: NoteKind) -> String {
        kind == .drum ? "Track \(trackNumber) (drum)" : "Track \(trackNumber)"
    }
}

public struct ArrangedTrack: Sendable, Hashable {
    public let name: String
    public let notes: [RenderedNote]

    public init(name: String, notes: [RenderedNote]) {
        self.name = name
        self.notes = notes
    }
}

public struct PatternBoundary: Sendable, Hashable {
    public let patternNumber: Int
    public let tick: Int

    public init(patternNumber: Int, tick: Int) {
        self.patternNumber = patternNumber
        self.tick = tick
    }

    public var markerText: String { "pattern \(patternNumber)" }
}

public struct Arrangement: Sendable, Hashable {
    public let tracks: [ArrangedTrack]
    public let lengthTicks: Int

    public let boundaries: [PatternBoundary]
    public let trackNumbers: [Int]
    public let diagnostics: Report

    public init(
        tracks: [ArrangedTrack], lengthTicks: Int, boundaries: [PatternBoundary],
        trackNumbers: [Int], diagnostics: Report = Report()
    ) {
        self.tracks = tracks
        self.lengthTicks = lengthTicks
        self.boundaries = boundaries
        self.trackNumbers = trackNumbers
        self.diagnostics = diagnostics
    }

    public var patternNumbers: [Int] {
        var seen: Set<Int> = []
        return boundaries.map(\.patternNumber).filter { seen.insert($0).inserted }
    }

    public var warnings: [String] { diagnostics.messages }

    public var noteCount: Int { tracks.reduce(0) { $0 + $1.notes.count } }
}

public struct ExportResult: Sendable {
    public let midi: MusicalMIDI1File
    public let noteCount: Int
    public let patternNumbers: [Int]

    public let trackNames: [String]
    public let diagnostics: Report

    public let trackNumbers: [Int]

    public init(
        midi: MusicalMIDI1File, noteCount: Int, patternNumbers: [Int], trackNames: [String],
        diagnostics: Report, trackNumbers: [Int] = []
    ) {
        self.midi = midi
        self.noteCount = noteCount
        self.patternNumbers = patternNumbers
        self.trackNames = trackNames
        self.diagnostics = diagnostics
        self.trackNumbers = trackNumbers
    }

    public var warnings: [String] { diagnostics.messages }

    public var isEmpty: Bool { noteCount == 0 }
}

extension MIDIExport {
    public static func declaredStepCount(_ pattern: Pattern, _ kind: NoteKind) -> Int {
        if kind == .drum, let drum = pattern.drumStepCount { return drum }
        return pattern.seqStepCount
    }

    public static func ticksPerStep(_ pattern: Pattern, _ kind: NoteKind, ticksPerBeat: Int) -> Int
    {
        let bits = pattern.bits(kind)
        let ticks = Arithmetic.floorDiv(ticksPerBeat * 4, bits.stepDenominator)
        return bits.triplet ? Arithmetic.floorDiv(ticks * 2, 3) : ticks
    }

    public static func autoPasses(_ notes: [Note]) -> Int {
        let partial = notes.contains { $0.skip.count != Constants.skipCyclePasses }
        return partial ? Constants.skipCyclePasses : 1
    }

    public static func swingPercent(_ pattern: Pattern, _ kind: NoteKind) -> Int {
        if kind == .drum, let drum = pattern.drumSwingPercent { return drum }
        return pattern.seqSwingPercent
    }

    public static func stepCount(_ pattern: Pattern, _ kind: NoteKind, notes: [Note]? = nil) -> Int
    {
        let subject = notes ?? pattern.notes(of: kind)
        return max(declaredStepCount(pattern, kind), subject.map(\.step).max() ?? 0)
    }

    /// `step` is **0-based**, unlike the 1-based step a note parameter stores.
    public static func swingDelay(_ step: Int, _ swingPercent: Int, _ ticksPerStep: Double)
        -> Double
    {
        guard Arithmetic.floorMod(step, 2) != 0 else { return 0 }
        return Double(Arithmetic.pyRound(ticksPerStep * (2 * Double(swingPercent) / 100 - 1)))
    }

    public static func renderPattern(
        _ pattern: Pattern, trackNumber: Int, kind: NoteKind, options: ExportOptions? = nil
    ) throws -> Rendering {
        let options = try options ?? ExportOptions()
        let collector = Collector()
        let site = Site(track: trackNumber, pattern: pattern.number, kind: kind.rawValue)
        let stepTicks = ticksPerStep(pattern, kind, ticksPerBeat: options.ticksPerBeat)

        let last = declaredStepCount(pattern, kind)
        var playable = pattern.notes(of: kind)
        let stepOff = playable.filter { disablement($0, lastStep: last) == .stepTurnedOff }
        let pastLast = playable.filter { disablement($0, lastStep: last) == .pastLastStep }
        var saidStepOff = false

        if options.includeDisabled {
            if !stepOff.isEmpty || !pastLast.isEmpty {
                collector.add(
                    .disabledExported,
                    "\(stepOff.count + pastLast.count) disabled note(s) were exported because "
                        + "--include-disabled is set; the device does not play them",
                    site: site, subjects: stepOff.count + pastLast.count)
            }
        } else {
            if !stepOff.isEmpty {
                collector.add(
                    .disabledNotExported,
                    "\(stepOff.count) disabled note(s), step turned off, were not exported; "
                        + "--include-disabled exports them",
                    site: site, subjects: stepOff.count)
                saidStepOff = true
            }
            if !pastLast.isEmpty {
                collector.add(
                    .disabledPastLastStep,
                    "\(pastLast.count) disabled note(s), past the last step of \(last), were not "
                        + "exported; --include-disabled exports them",
                    site: site, subjects: pastLast.count)
            }
            playable = playable.filter { disablement($0, lastStep: last) == nil }
        }

        let steps = stepCount(pattern, kind, notes: playable)
        let passTicks = steps * stepTicks
        let passes = options.passes ?? autoPasses(playable)
        let lengthTicks = passTicks * passes
        let swing = swingPercent(pattern, kind)
        let channel = kind == .drum ? options.drumChannel : trackNumber - 1

        let masked = playable.filter { $0.skip.count != Constants.skipCyclePasses }
        if !masked.isEmpty && passes > 1 {
            collector.add(
                .stepSkipExpanded,
                "rendered as \(passes) repeats so that \(masked.count) masked note(s) land on the "
                    + "16/32/48/64 sequences they play in",
                site: site, subjects: masked.count)
        } else if !masked.isEmpty {
            collector.add(
                .stepSkipSinglePass,
                "\(masked.count) note(s) play on only some of the 16/32/48/64 sequences, which "
                    + "the device runs as four repeats; one pass was rendered and all of them "
                    + "included",
                site: site, subjects: masked.count)
        }

        let direction = pattern.bits(kind).direction
        if direction != .forward {
            collector.add(
                .directionNotApplied,
                "plays \(direction.rawValue), which a MIDI file cannot express; the steps were "
                    + "rendered in forward order",
                site: site)
        }

        if kind == .drum {
            collector.add(
                .drumMapAssumed,
                "drum lanes resolved through the \(options.drumMap.describe()) map on channel "
                    + "\(options.drumChannel + 1); the KeyStep Pro drum map is a device global "
                    + "and is not stored in the project file (spec 3.2.1)")
            collector.extend(options.drumMap.diagnostics)
        }
        if options.applySwing && swing != Constants.swingRangePercent.min {
            collector.add(
                .swingUnverified,
                "uses \(swing)% swing; the device delays the even steps, which is what was "
                    + "exported, but how far one percent moves them is not measured",
                site: Site(pattern: pattern.number))
        }
        collector.extend(
            pattern.diagnostics
                .filter { !(saidStepOff && $0.code == .disabledStepOff) }
                .map { $0.at(track: trackNumber) })

        var renderedNotes: [(note: Note, rendered: RenderedNote)] = []
        for note in playable {
            guard
                var rendered = renderNote(
                    note, kind: kind, channel: channel, swing: swing, stepTicks: stepTicks,
                    options: options, collector: collector)
            else { continue }
            if rendered.tick + rendered.durationTicks > passTicks {
                collector.add(
                    .gateShortened,
                    "note(s) whose gate ran past the end of the pattern were shortened to it",
                    site: Site(pattern: pattern.number))
                rendered = rendered.with(durationTicks: max(1, passTicks - rendered.tick))
            }
            renderedNotes.append((note, rendered))
        }

        var notes: [RenderedNote] = []
        for index in 0..<passes {
            let sequence = Constants.skipSequences[index]
            let offset = index * passTicks
            for entry in renderedNotes {
                if passes > 1 && !entry.note.skip.contains(sequence) { continue }
                notes.append(
                    offset != 0
                        ? entry.rendered.with(tick: entry.rendered.tick + offset) : entry.rendered)
            }
        }

        return Rendering(
            trackNumber: trackNumber, kind: kind, patternNumber: pattern.number, notes: notes,
            lengthTicks: lengthTicks, diagnostics: collector.report())
    }

    static func renderNote(
        _ note: Note, kind: NoteKind, channel: Int, swing: Int, stepTicks: Int,
        options: ExportOptions, collector: Collector
    ) -> RenderedNote? {
        var pitch = note.pitch
        if kind == .drum {
            guard options.drumMap.hasLane(note.pitch),
                let mapped = try? options.drumMap.noteForLane(note.pitch)
            else {
                collector.add(
                    .drumLaneDropped,
                    "drum lane \(note.pitch) is outside the device's "
                        + "0-\(Constants.drumLaneCount - 1) lanes and was dropped")
                return nil
            }
            pitch = mapped
        }

        var tick = (note.step - 1) * stepTicks
        if options.applySwing {
            tick += Arithmetic.pyRound(swingDelay(note.step - 1, swing, Double(stepTicks)))
        }
        if options.applyTimeShift {
            tick += Constants.timeShiftTicks(note.timeShift, ticksPerBeat: options.ticksPerBeat)
        }

        var gate = note.gate
        if gate == nil {
            gate = options.defaultGate
            collector.add(
                .gateOffLadder,
                "gate encoding \(note.gateRaw) is off the 0-127 ladder and cannot be decoded; "
                    + "exported at the \(Arithmetic.general(options.defaultGate))-step default length"
            )
        }
        return RenderedNote(
            tick: tick,
            durationTicks: max(1, Arithmetic.pyRound((gate ?? 0) * Double(stepTicks))),
            pitch: pitch,
            velocity: options.flatVelocity ?? max(minVelocity, note.velocity),
            channel: channel)
    }
}

extension MIDIExport {
    static func placed(_ note: RenderedNote, offset: Int, collector: Collector) -> RenderedNote {
        let tick = note.tick + offset
        if tick >= 0 { return note.with(tick: tick) }
        collector.add(
            .timeShiftClipped,
            "a note's time shift places it \(-tick) tick(s) before the start of the export; "
                + "it was held at the start instead")
        return note.with(tick: 0)
    }

    public static func arrange(_ renderings: [Rendering], repeat count: Int = 1) throws
        -> Arrangement
    {
        if !(1...maxRepeat ~= count) {
            throw KSPError.value("repeat must be 1-\(maxRepeat)")
        }

        let collector = Collector()
        for rendering in renderings {
            collector.extend(rendering.diagnostics)
        }

        var lengths: [Int: Int] = [:]
        for rendering in renderings {
            let number = rendering.patternNumber
            lengths[number] = max(lengths[number] ?? 0, rendering.lengthTicks)
        }

        var offsets: [Int: Int] = [:]
        var cursor = 0
        for number in lengths.keys.sorted() {
            offsets[number] = cursor
            cursor += lengths[number] ?? 0
        }

        // MIDI track order is the order names were first seen, which a Dictionary cannot hold.
        var names: [String] = []
        var groups: [String: [RenderedNote]] = [:]
        let ordered = renderings.stableSorted { left, right in
            (left.trackNumber, left.kind == .drum ? 1 : 0, left.patternNumber)
                < (right.trackNumber, right.kind == .drum ? 1 : 0, right.patternNumber)
        }
        for rendering in ordered {
            let name = rendering.midiTrackName
            if groups[name] == nil {
                names.append(name)
                groups[name] = []
            }
            for repetition in 0..<count {
                let offset = repetition * cursor + (offsets[rendering.patternNumber] ?? 0)
                groups[name]?.append(
                    contentsOf: rendering.notes.map {
                        placed($0, offset: offset, collector: collector)
                    })
            }
        }

        warnOnUnequalTracks(renderings, collector: collector)
        let tracks = names.compactMap { name -> ArrangedTrack? in
            guard let notes = groups[name], !notes.isEmpty else { return nil }
            return ArrangedTrack(name: name, notes: resolveOverlaps(notes, collector: collector))
        }
        return Arrangement(
            tracks: tracks,
            lengthTicks: cursor * count,
            boundaries: (0..<count).flatMap { repetition in
                offsets.sorted { $0.key < $1.key }.map {
                    PatternBoundary(patternNumber: $0.key, tick: repetition * cursor + $0.value)
                }
            },
            trackNumbers: Set(renderings.map(\.trackNumber)).sorted(),
            diagnostics: collector.report())
    }

    static func warnOnUnequalTracks(_ renderings: [Rendering], collector: Collector) {
        var totals: [Int: [Int: Int]] = [:]
        for rendering in renderings {
            var byPattern = totals[rendering.trackNumber] ?? [:]
            byPattern[rendering.patternNumber] = max(
                byPattern[rendering.patternNumber] ?? 0, rendering.lengthTicks)
            totals[rendering.trackNumber] = byPattern
        }
        let lengths = totals.mapValues { $0.values.reduce(0, +) }
        guard Set(lengths.values).count > 1 else { return }
        let summary = lengths.keys.sorted()
            .map { "track \($0): \(lengths[$0] ?? 0) ticks" }
            .joined(separator: ", ")
        collector.add(
            .trackLengthsDiffer,
            "tracks hold different total lengths (\(summary)); this export aligns pattern N "
                + "across tracks, but the device loops each track on its own, so they drift apart")
    }

    static func resolveOverlaps(_ notes: [RenderedNote], collector: Collector) -> [RenderedNote] {
        // The device retriggers, so an overlapping earlier note is shortened, not left hanging.
        let ordered = notes.stableSorted { ($0.tick, $0.pitch) < ($1.tick, $1.pitch) }
        var resolved: [RenderedNote] = []
        var previous: [Pair: Int] = [:]  // (channel, pitch) -> index in resolved
        for note in ordered {
            let key = Pair(note.channel, note.pitch)
            if let index = previous[key] {
                let earlier = resolved[index]
                if earlier.tick + earlier.durationTicks > note.tick {
                    resolved[index] = earlier.with(
                        durationTicks: max(1, note.tick - earlier.tick))
                    collector.add(
                        .overlapsResolved,
                        "overlapping note(s) of the same pitch were shortened so each has its "
                            + "own note-off")
                }
            }
            previous[key] = resolved.count
            resolved.append(note)
        }
        return resolved
    }
}

struct Pair: Hashable {
    let first: Int
    let second: Int

    init(_ first: Int, _ second: Int) {
        self.first = first
        self.second = second
    }
}

extension MIDIExport {
    public static func buildMIDIFile(
        _ arrangement: Arrangement, name: String, tempoBPM: Double, ticksPerBeat: Int,
        markers: Bool = true
    ) -> MusicalMIDI1File {
        var tracks = [
            conductorTrack(
                name: name, tempoBPM: tempoBPM, totalTicks: arrangement.lengthTicks,
                boundaries: markers ? arrangement.boundaries : [])
        ]
        tracks.append(contentsOf: arrangement.tracks.map(midiTrack))
        return MusicalMIDI1File(
            format: .multipleTracksSynchronous,
            timebase: .init(ticksPerQuarterNote: UInt16(ticksPerBeat)),
            tracks: tracks)
    }

    /// Rounded as mido does; `SwiftMIDIFile`'s `tempo(bpm:)` truncates and would disagree by one.
    static func bpmToMicroseconds(_ bpm: Double) -> UInt32 {
        UInt32(Arithmetic.pyRound(60 * 1_000_000 / bpm))
    }

    static func conductorTrack(
        name: String, tempoBPM: Double, totalTicks: Int, boundaries: [PatternBoundary]
    )
        -> MusicalMIDI1File.Track
    {
        var track = MusicalMIDI1File.Track()
        track.events.append(.text(type: .trackOrSequenceName, string: name))
        track.events.append(
            .init(
                delta: .none,
                event: .tempo(
                    .musical(
                        MIDIFileEvent.MusicalTempo(
                            microsecondsPerQuarter: bpmToMicroseconds(tempoBPM))))))
        track.events.append(.timeSignature(numerator: 4, denominator: 2))

        var previousTick = 0
        for boundary in boundaries {
            track.events.append(
                .text(
                    delta: .ticks(UInt32(boundary.tick - previousTick)), type: .marker,
                    string: boundary.markerText))
            previousTick = boundary.tick
        }
        track.deltaTimeBeforeEndOfTrack = .ticks(UInt32(totalTicks - previousTick))
        return track
    }

    static func midiTrack(_ arranged: ArrangedTrack) -> MusicalMIDI1File.Track {
        var track = MusicalMIDI1File.Track()
        track.events.append(.text(type: .trackOrSequenceName, string: arranged.name))

        // note_off sorts before note_on at the same tick, or a retrigger reads as a hanging note.
        var timed: [(tick: Int, rank: Int, pitch: Int, note: RenderedNote)] = []
        for note in arranged.notes {
            timed.append((note.tick, 1, note.pitch, note))
            timed.append((note.tick + note.durationTicks, 0, note.pitch, note))
        }
        let sorted = timed.stableSorted {
            ($0.tick, $0.rank, $0.pitch) < ($1.tick, $1.rank, $1.pitch)
        }

        var previousTick = 0
        for entry in sorted {
            let delta = MusicalMIDIFileDeltaTime.ticks(UInt32(entry.tick - previousTick))
            let pitch = UInt7(entry.note.pitch)
            let channel = UInt4(entry.note.channel)
            if entry.rank == 1 {
                track.events.append(
                    .noteOn(
                        delta: delta, note: pitch,
                        velocity: .midi1(UInt7(entry.note.velocity)), channel: channel))
            } else {
                track.events.append(
                    .noteOff(
                        delta: delta, note: pitch, velocity: .midi1(0), channel: channel))
            }
            previousTick = entry.tick
        }
        return track
    }
}

extension MIDIExport {
    public static func exportProject(_ project: Project, options: ExportOptions? = nil) throws
        -> ExportResult
    {
        let options = try options ?? ExportOptions()
        let renderings = try renderProject(project, options: options)
        return try result(
            arrange(renderings, repeat: options.repeatCount), project: project, options: options)
    }

    public static func exportSplit(_ project: Project, options: ExportOptions? = nil) throws
        -> [ExportResult]
    {
        let options = try options ?? ExportOptions()
        var keys: [Pair] = []
        var parts: [Pair: [Rendering]] = [:]
        for rendering in try renderProject(project, options: options) {
            let key = Pair(rendering.trackNumber, rendering.patternNumber)
            if parts[key] == nil {
                keys.append(key)
                parts[key] = []
            }
            parts[key]?.append(rendering)
        }

        return
            try keys
            .sorted { ($0.first, $0.second) < ($1.first, $1.second) }
            .compactMap { key -> ExportResult? in
                guard let group = parts[key] else { return nil }
                let result = try result(
                    arrange(group, repeat: options.repeatCount), project: project, options: options)
                return result.isEmpty ? nil : result
            }
    }

    public static func renderProject(_ project: Project, options: ExportOptions? = nil) throws
        -> [Rendering]
    {
        let options = try options ?? ExportOptions()
        var plans: [(track: Track, pattern: Pattern, kind: NoteKind, stale: Diagnostic?)] = []
        for track in project.tracks {
            let live: NoteKind = track.drumMode ? .drum : .seq
            for pattern in track.patterns {
                let populated = [NoteKind.seq, .drum].filter { !pattern.notes(of: $0).isEmpty }
                var kinds = populated
                var staleDiagnostic: Diagnostic?
                if populated.count > 1 && !options.includeStale {
                    kinds = [live]
                    let stale = populated.first { $0 != live } ?? live
                    staleDiagnostic = Diagnostic(
                        code: .staleNoteSet,
                        detail:
                            "holds both melodic (\(pattern.notes(of: .seq).count)) and drum "
                            + "(\(pattern.notes(of: .drum).count)) notes; parameter 86 bit 6 says "
                            + "\(live.rawValue) plays, so the \(stale.rawValue) set was not "
                            + "exported (--include-stale exports both)",
                        site: Site(track: track.number, pattern: pattern.number))
                }
                for kind in kinds {
                    plans.append((track, pattern, kind, staleDiagnostic))
                }
            }
        }

        var columnPasses: [Int: Int] = [:]
        for plan in plans {
            let number = plan.pattern.number
            columnPasses[number] = max(
                columnPasses[number] ?? 1, autoPasses(plan.pattern.notes(of: plan.kind)))
        }

        var renderings: [Rendering] = []
        for plan in plans {
            let passes = options.passes ?? columnPasses[plan.pattern.number] ?? 1
            var rendering = try renderPattern(
                plan.pattern, trackNumber: plan.track.number, kind: plan.kind,
                options: options.with(passes: passes))
            if let stale = plan.stale {
                let kept = rendering.diagnostics.entries.filter { $0.code != .mixedNoteSets }
                rendering = Rendering(
                    trackNumber: rendering.trackNumber, kind: rendering.kind,
                    patternNumber: rendering.patternNumber, notes: rendering.notes,
                    lengthTicks: rendering.lengthTicks, diagnostics: Report([stale] + kept))
            }
            renderings.append(rendering)
        }
        return renderings
    }

    static func result(_ arrangement: Arrangement, project: Project, options: ExportOptions)
        -> ExportResult
    {
        var diagnostics = arrangement.diagnostics
        if options.applySwing && project.globalSwingPercent != Constants.swingRangePercent.min {
            let globalSwing = Diagnostic(
                code: .globalSwingNotApplied,
                detail:
                    "project sets a \(project.globalSwingPercent)% global swing (parameter 74); "
                    + "the per-pattern value takes precedence on the device, so the global was "
                    + "not applied")
            diagnostics = Report([globalSwing] + diagnostics.entries)
        }
        return ExportResult(
            midi: buildMIDIFile(
                arrangement,
                name: project.sourceName.isEmpty ? project.device : project.sourceName,
                tempoBPM: project.tempoBPM,
                ticksPerBeat: options.ticksPerBeat,
                markers: options.markers),
            noteCount: arrangement.noteCount,
            patternNumbers: arrangement.patternNumbers,
            trackNames: arrangement.tracks.map(\.name),
            diagnostics: diagnostics,
            trackNumbers: arrangement.trackNumbers)
    }
}
