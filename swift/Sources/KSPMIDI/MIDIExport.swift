import Foundation
import KSPKit
import SwiftMIDIFile

/// Rendering a decoded project as one or more Standard MIDI files. The device stores no
/// arrangement, so merged lays note-bearing patterns end to end with pattern N at the same tick on
/// every track, while `--split` writes one file per pattern at tick 0 and invents no layout.
public enum MIDIExport {
    /// Divides by 3 and 4, so every step size stays exact: the finest is a 1/32 triplet at 20 ticks.
    public static let defaultTicksPerBeat = 480

    /// What `ticksPerBeat` must divide by: 1/32 needs 8, and a triplet needs 3.
    public static let ticksPerBeatDivisor = 24

    /// The device's Drum output default is channel 10 counting from 1; MIDI counts from 0.
    public static let drumChannel = DrumMap.defaultDrumChannel - 1

    /// A note stored with velocity 0 is silent on the device but reads as a note-off in MIDI.
    public static let minVelocity = 1

    /// Export-only: `Constants.sentinel` is 127 too, but marks an empty slot.
    public static let maxVelocity = 127

    /// A flat render substitutes what a freshly placed note carries on the device.
    public static let defaultFlatVelocity = Constants.freshVelocity

    /// How many times an arrangement may be laid down end to end. Export-only, unlike `passes`.
    public static let maxRepeat = 10
}

/// Everything the project file cannot tell us about timing and mapping.
public struct ExportOptions: Sendable, Hashable {
    public let ticksPerBeat: Int
    public let drumMap: DrumMap
    public let drumChannel: Int

    /// Length in steps for a gate off the 0-127 ladder; only a corrupt file reaches it.
    public let defaultGate: Double

    /// Swing percent is decoded, but how far one percent moves a step is the standard formula.
    public let applySwing: Bool

    /// Displace each note by its stored time shift, a fixed 1/400 of a beat per unit.
    public let applyTimeShift: Bool

    /// Export both note sets of a pattern holding both, not just the one 86 bit 6 plays.
    public let includeStale: Bool

    /// Export notes the device does not play: step turned off, or past the last step.
    public let includeDisabled: Bool

    /// Mark each pattern's start with a marker meta event, for a DAW's marker ruler.
    public let markers: Bool

    /// How many of the four 16/32/48/64 repeats to render; `nil` is auto.
    public let passes: Int?

    /// Render every note at this velocity, reading a pattern's written rather than audible
    /// content. `nil` keeps the stored values; 0 is unavailable, being a note-off in MIDI.
    public let flatVelocity: Int?

    /// How many times to lay the whole export down end to end. Export-only, unlike `passes`.
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
        if let flatVelocity,
            !(MIDIExport.minVelocity...MIDIExport.maxVelocity ~= flatVelocity)
        {
            throw KSPError.value(
                "flat_velocity must be \(MIDIExport.minVelocity)-\(MIDIExport.maxVelocity); "
                    + "0 is a MIDI note-off, not a silent note")
        }
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

    /// A copy with a different pass count.
    func with(passes: Int?) throws -> ExportOptions {
        try ExportOptions(
            ticksPerBeat: ticksPerBeat, drumMap: drumMap, drumChannel: drumChannel,
            defaultGate: defaultGate, applySwing: applySwing, applyTimeShift: applyTimeShift,
            includeStale: includeStale, includeDisabled: includeDisabled, markers: markers,
            passes: passes, flatVelocity: flatVelocity, repeatCount: repeatCount)
    }
}

/// One note as a DAW will see it, in ticks. No MIDI library involved.
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

/// One parameter set of one pattern, rendered from its own tick 0.
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

    /// What a track is called in an exported `.mid`, shared so a preview cannot drift from it.
    public static func trackName(_ trackNumber: Int, kind: NoteKind) -> String {
        kind == .drum ? "Track \(trackNumber) (drum)" : "Track \(trackNumber)"
    }
}

/// One MIDI track's worth of notes, at absolute ticks.
public struct ArrangedTrack: Sendable, Hashable {
    public let name: String
    public let notes: [RenderedNote]

    public init(name: String, notes: [RenderedNote]) {
        self.name = name
        self.notes = notes
    }
}

/// Where one pattern starts on the timeline, and which pattern it is.
public struct PatternBoundary: Sendable, Hashable {
    public let patternNumber: Int
    public let tick: Int

    public init(patternNumber: Int, tick: Int) {
        self.patternNumber = patternNumber
        self.tick = tick
    }

    public var markerText: String { "pattern \(patternNumber)" }
}

/// Renderings placed on a timeline, ready to become a file.
public struct Arrangement: Sendable, Hashable {
    public let tracks: [ArrangedTrack]
    public let lengthTicks: Int

    /// Ascending by tick: the build layer walks them into MIDI deltas.
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

    /// Which patterns are in this file, not how often each is played.
    public var patternNumbers: [Int] {
        var seen: Set<Int> = []
        return boundaries.map(\.patternNumber).filter { seen.insert($0).inserted }
    }

    public var warnings: [String] { diagnostics.messages }

    public var noteCount: Int { tracks.reduce(0) { $0 + $1.notes.count } }
}

/// A rendered file plus what the caller should be told about it.
public struct ExportResult: Sendable {
    public let midi: MusicalMIDI1File
    public let noteCount: Int
    public let patternNumbers: [Int]

    /// Stops matching ``trackNumbers`` once track 1's drum set becomes a track of its own.
    public let trackNames: [String]
    public let diagnostics: Report

    /// KeyStep Pro track numbers in this file -- what a split export names its files after.
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
    /// The step count the pattern declares for `kind`.
    public static func declaredStepCount(_ pattern: Pattern, _ kind: NoteKind) -> Int {
        if kind == .drum, let drum = pattern.drumStepCount { return drum }
        return pattern.seqStepCount
    }

    /// How long one step is, from the pattern's own `99`/`116` step size and triplet (spec 3.3).
    public static func ticksPerStep(_ pattern: Pattern, _ kind: NoteKind, ticksPerBeat: Int) -> Int
    {
        let bits = pattern.bits(kind)
        let ticks = Arithmetic.floorDiv(ticksPerBeat * 4, bits.stepDenominator)
        return bits.triplet ? Arithmetic.floorDiv(ticks * 2, 3) : ticks
    }

    /// Four when any note sits out one of the four repeats, else one.
    public static func autoPasses(_ notes: [Note]) -> Int {
        let partial = notes.contains { $0.skip.count != Constants.skipCyclePasses }
        return partial ? Constants.skipCyclePasses : 1
    }

    public static func swingPercent(_ pattern: Pattern, _ kind: NoteKind) -> Int {
        if kind == .drum, let drum = pattern.drumSwingPercent { return drum }
        return pattern.seqSwingPercent
    }

    /// Declared length, widened to hold any note past it -- reachable only with `includeDisabled`.
    public static func stepCount(_ pattern: Pattern, _ kind: NoteKind, notes: [Note]? = nil) -> Int
    {
        let subject = notes ?? pattern.notes(of: kind)
        return max(declaredStepCount(pattern, kind), subject.map(\.step).max() ?? 0)
    }

    /// Ticks the device delays `step` by. **0-based**, unlike the note parameters' 1-based step.
    public static func swingDelay(_ step: Int, _ swingPercent: Int, _ ticksPerStep: Double)
        -> Double
    {
        // At p percent the first step of a pair takes p of it, so the second starts 2*p/100 - 1
        // steps late; 50% is no swing.
        guard Arithmetic.floorMod(step, 2) != 0 else { return 0 }
        return Double(Arithmetic.pyRound(ticksPerStep * (2 * Double(swingPercent) / 100 - 1)))
    }

    /// Turn one parameter set of one pattern into plain tick data, counted from its own start.
    public static func renderPattern(
        _ pattern: Pattern, trackNumber: Int, kind: NoteKind, options: ExportOptions? = nil
    ) throws -> Rendering {
        let options = try options ?? ExportOptions()
        let collector = Collector()
        let site = Site(track: trackNumber, pattern: pattern.number, kind: kind.rawValue)
        let stepTicks = ticksPerStep(pattern, kind, ticksPerBeat: options.ticksPerBeat)

        // Filter before measuring: a note the device does not play must not stretch its pattern.
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
        // The reader's step-off finding is dropped where the export has just named the flag that
        // brings those notes back.
        collector.extend(
            pattern.diagnostics
                .filter { !(saidStepOff && $0.code == .disabledStepOff) }
                .map { $0.at(track: trackNumber) })

        // Rendered once per note, then replicated, so a note's diagnostics are raised once.
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
                // One pass renders everything: the mask means nothing without the repeats.
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
            // A lane outside the map has no note to emit, so it is dropped loudly.
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
            // Independent of the step size, so taken from the beat rather than from stepTicks.
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
    /// Move `note` onto the timeline, holding it at tick 0 -- and saying so -- if it lands before.
    static func placed(_ note: RenderedNote, offset: Int, collector: Collector) -> RenderedNote {
        let tick = note.tick + offset
        if tick >= 0 { return note.with(tick: tick) }
        collector.add(
            .timeShiftClipped,
            "a note's time shift places it \(-tick) tick(s) before the start of the export; "
                + "it was held at the start instead")
        return note.with(tick: 0)
    }

    /// Lay renderings end to end in pattern order, each pattern occupying the longest length any
    /// track gives it so unequal tracks stay aligned at every boundary. `repeat` is not `passes`.
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
        // A repeat is placed, not copied afterwards, so overlaps across rounds resolve normally.
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

    /// Say so when the tracks do not add up to the same length: this export restarts them all at
    /// each pattern boundary, where the device loops each independently.
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

    /// Stop a long gate from swallowing the next note of the same pitch.
    static func resolveOverlaps(_ notes: [RenderedNote], collector: Collector) -> [RenderedNote] {
        // Two note-ons for one pitch with one note-off between them hangs in most DAWs; the
        // device retriggers, so the earlier note is shortened instead.
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

/// Two integers as one hashable key.
struct Pair: Hashable {
    let first: Int
    let second: Int

    init(_ first: Int, _ second: Int) {
        self.first = first
        self.second = second
    }
}

extension MIDIExport {
    /// Turn an arrangement into a type-1 MIDI file. The only `SwiftMIDIFile` layer.
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

    /// Microseconds per quarter note, rounded as mido does -- not `SwiftMIDIFile`'s `tempo(bpm:)`,
    /// which truncates, and would disagree by one microsecond on a fractional BPM.
    static func bpmToMicroseconds(_ bpm: Double) -> UInt32 {
        UInt32(Arithmetic.pyRound(60 * 1_000_000 / bpm))
    }

    /// Track 0: name, tempo, time signature and the pattern markers, no notes.
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
        // End-of-track sits at the end of the last pattern, not the last note.
        track.deltaTimeBeforeEndOfTrack = .ticks(UInt32(totalTicks - previousTick))
        return track
    }

    /// Turn absolute-tick notes into a delta-time MIDI track.
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
    /// Render `project` as a single type-1 MIDI file; narrow with `Project.select` first.
    public static func exportProject(_ project: Project, options: ExportOptions? = nil) throws
        -> ExportResult
    {
        let options = try options ?? ExportOptions()
        let renderings = try renderProject(project, options: options)
        return try result(
            arrange(renderings, repeat: options.repeatCount), project: project, options: options)
    }

    /// One file per non-empty (track, pattern), each starting at tick 0 with nothing laid out
    /// across patterns.
    public static func exportSplit(_ project: Project, options: ExportOptions? = nil) throws
        -> [ExportResult]
    {
        let options = try options ?? ExportOptions()
        var keys: [Pair] = []
        var parts: [Pair: [Rendering]] = [:]
        for rendering in try renderProject(project, options: options) {
            // Under --include-stale track 1 contributes two renderings to the same file.
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

    /// Render every (track, pattern, parameter set) that holds notes and plays. An automatic pass
    /// count is resolved across a pattern column, keeping pattern N aligned on every track.
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
                    // Only when both sets hold notes does the flag have to decide; a pattern
                    // holding one set is exported whatever the flag says.
                    kinds = [live]
                    let stale = populated.first { $0 != live } ?? live
                    // Carries the reader's own counts, so its line can be dropped below.
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
                // This says what the reader's line says and which flag brings the other set back.
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
        // The per-pattern value takes precedence on the device, so the global is reported only.
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
