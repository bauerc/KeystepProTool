import Foundation
import KSPKit
import SwiftMIDIFile

/// Rendering a decoded project as one or more Standard MIDI files -- a port of
/// `src/ksp/midi_export.py`.
///
/// The device stores no arrangement -- 4 tracks x 16 independent pattern loops -- so turning that
/// into a linear file means choosing a layout. Merged (the default) lays note-bearing patterns end
/// to end with pattern N at the same tick on every track; `--split` writes one file per pattern at
/// tick 0 and invents no layout at all.
///
/// Three layers, and the split is what makes the port a translation of arithmetic rather than of a
/// MIDI library: ``renderPattern`` -> ``arrange`` -> ``buildMIDIFile``, the only one of the three
/// that knows what `SwiftMIDIFile` is.
public enum MIDIExport {
    /// 480 divides evenly by 3 and 4, so every step size the device offers stays exact, triplets
    /// included: the finest is a 1/32 triplet at 20 ticks.
    public static let defaultTicksPerBeat = 480

    /// What `ticksPerBeat` must divide by for every step size x triplet combination to land on a
    /// whole tick: 1/32 needs 8, and a triplet needs 3.
    public static let ticksPerBeatDivisor = 24

    /// The device's Drum output default (`globalParamId 79`) is channel 10, counting from 1; MIDI
    /// messages count channels from 0.
    public static let drumChannel = DrumMap.defaultDrumChannel - 1

    /// A note stored with velocity 0 is silent on the device and would read as a note-off in MIDI,
    /// which is a different thing. Exported at 1 instead.
    public static let minVelocity = 1

    /// The loudest a MIDI note-on can be. Export-only, like `minVelocity`: `Constants.sentinel`
    /// is 127 as well but marks an empty slot, so a velocity limit must not be spelled with it.
    public static let maxVelocity = 127

    /// What a flat render substitutes unless the caller names another value: the measured
    /// velocity a freshly placed note carries on the device, so a flat export sounds like the
    /// pattern unedited rather than like an invented default. Named here so nothing above has to
    /// re-type the number.
    public static let defaultFlatVelocity = Constants.freshVelocity

    /// How many times an arrangement may be laid down end to end. Export-only: the device stores
    /// no such count, so this is not `passes` and no repeat of it can be written back to a project
    /// file.
    public static let maxRepeat = 10
}

/// Everything the project file cannot tell us about timing and mapping.
public struct ExportOptions: Sendable, Hashable {
    public let ticksPerBeat: Int
    public let drumMap: DrumMap
    public let drumChannel: Int

    /// Length in steps for a gate value off the 0-127 ladder. Every legal value decodes (spec
    /// 6.1), so this only fires on a corrupt file.
    public let defaultGate: Double

    /// Swing percent is decoded, but how far one percent moves a step is the standard formula
    /// rather than a measured one. Off gives a flat grid.
    public let applySwing: Bool

    /// Displace each note by its stored time shift, measured by tier 8 as a fixed 1/400 of a beat
    /// per unit.
    public let applyTimeShift: Bool

    /// Export both note sets of a pattern that holds both, rather than the one parameter 86 bit 6
    /// says the device plays.
    public let includeStale: Bool

    /// Export disabled notes -- step turned off, and past the pattern's last step. The device
    /// plays neither, so exporting them invents audio the hardware never makes.
    public let includeDisabled: Bool

    /// Mark the start of every pattern with a marker meta event, so a DAW's marker ruler shows
    /// where one pattern ends and the next begins. A merged export is otherwise an
    /// undifferentiated run of notes whose seams can only be found by eye.
    public let markers: Bool

    /// How many of the four 16/32/48/64 repeats to render. `nil` is auto: four when a pattern
    /// holds a note that does not play on all four, one otherwise.
    public let passes: Int?

    /// Render every note at this velocity instead of the one it stores. `nil` keeps the stored
    /// values, which is what an export of a performance wants; a flat render reads a pattern's
    /// *written* content. `MIDIExport.defaultFlatVelocity` is the value to pass to hear the
    /// pattern as the device would have played it unedited. A note stored at velocity 0 is silent
    /// on the device but takes the fixed value like any other, so a flat render can sound a note
    /// the hardware does not -- written content, not audible content. 0 itself is not available:
    /// it is a note-off in MIDI, not a silent note.
    public let flatVelocity: Int?

    /// How many times to lay the whole export down end to end, 1-``MIDIExport/maxRepeat``.
    /// Export-only: the device stores no such count, so this is not `passes` and no repeat of it
    /// can be written back to a project file.
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

    /// A copy with a different pass count, standing in for Python's `replace(options, passes=)`.
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

    /// What a track is called in an exported `.mid`. Named here rather than at each site so a
    /// preview of a project and the file it exports to cannot drift apart.
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

    /// Which patterns are in this file, not how often each is played: a repeat count puts the same
    /// pattern on the timeline more than once.
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

    /// The MIDI track names, which stop matching ``trackNumbers`` once Track 1's drum set becomes
    /// a track of its own.
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

// MARK: - Layer 1: pattern to tick data

extension MIDIExport {
    /// The step count the pattern declares for `kind`.
    public static func declaredStepCount(_ pattern: Pattern, _ kind: NoteKind) -> Int {
        if kind == .drum, let drum = pattern.drumStepCount { return drum }
        return pattern.seqStepCount
    }

    /// How long one step of `pattern` is, from its own step size and triplet.
    ///
    /// Both come out of the `99`/`116` bitfield (spec 3.3), so nothing here is a caller's
    /// assumption: a 1/16 pattern at 480 ticks per beat is 120 ticks a step, and its triplet is 80.
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

    /// Declared length, widened to hold any note that sits past it.
    ///
    /// Only reachable with `includeDisabled`, which keeps notes past the last step; the pattern is
    /// widened so they still land where the file puts them.
    public static func stepCount(_ pattern: Pattern, _ kind: NoteKind, notes: [Note]? = nil) -> Int
    {
        let subject = notes ?? pattern.notes(of: kind)
        return max(declaredStepCount(pattern, kind), subject.map(\.step).max() ?? 0)
    }

    /// Ticks the device delays `step` by. **0-based**: step 1 is the second of the pair.
    ///
    /// Both directions share this, so a groove that survives one survives the other. Callers
    /// holding a 1-based step index must subtract one -- the note parameter numbers steps from 1,
    /// this does not.
    public static func swingDelay(_ step: Int, _ swingPercent: Int, _ ticksPerStep: Double)
        -> Double
    {
        // Standard swing: at p percent the first step of a pair takes p of the pair, so the second
        // starts 2*p/100 - 1 steps late. 50% is no swing.
        guard Arithmetic.floorMod(step, 2) != 0 else { return 0 }
        return Double(Arithmetic.pyRound(ticksPerStep * (2 * Double(swingPercent) / 100 - 1)))
    }

    /// Turn one parameter set of one pattern into plain tick data.
    ///
    /// Ticks count from the pattern's own start, so the caller decides where the pattern sits.
    /// This is where every timing decision is made and what the tests assert against.
    public static func renderPattern(
        _ pattern: Pattern, trackNumber: Int, kind: NoteKind, options: ExportOptions? = nil
    ) throws -> Rendering {
        let options = try options ?? ExportOptions()
        let collector = Collector()
        let site = Site(track: trackNumber, pattern: pattern.number, kind: kind.rawValue)
        let stepTicks = ticksPerStep(pattern, kind, ticksPerBeat: options.ticksPerBeat)

        // Filter before measuring: a note the device does not play must not stretch the pattern it
        // sits in. Both ways of being disabled are dropped together -- the user turned these off,
        // so the default export is what the device plays, not everything the file holds.
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
        // A pattern the reader could not fully resolve produces MIDI that is confidently wrong in
        // a way the file itself will not reveal. The reader's own step-off finding is dropped when
        // the export has just said the same thing more usefully -- it names the flag that brings
        // the notes back.
        collector.extend(
            pattern.diagnostics
                .filter { !(saidStepOff && $0.code == .disabledStepOff) }
                .map { $0.at(track: trackNumber) })

        // Rendered once per note, then replicated: a note's tick data does not change between
        // passes, and rendering it four times would say anything it has to say -- an off-ladder
        // gate, an unapplied time shift -- four times.
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
                // One pass renders everything: the mask has no meaning without the repeats it
                // selects between.
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
            // A lane the device does not have means parameter 117 is not the 0-based lane index we
            // think it is. The reader already warns; here there is simply no note to emit, so the
            // note is dropped loudly.
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
            // Independent of the step size, so it is taken from the beat rather than from
            // stepTicks (tier 8, R1 against R3).
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

// MARK: - Layer 2: timeline placement

extension MIDIExport {
    /// Move `note` onto the timeline, holding it at tick 0 if it lands before it.
    ///
    /// Only a negative time shift on the first step of the first pattern can go negative, and MIDI
    /// has nowhere to put it. The note keeps its length and is reported, because silently moving
    /// an onset is the failure this whole tier exists to avoid.
    static func placed(_ note: RenderedNote, offset: Int, collector: Collector) -> RenderedNote {
        let tick = note.tick + offset
        if tick >= 0 { return note.with(tick: tick) }
        collector.add(
            .timeShiftClipped,
            "a note's time shift places it \(-tick) tick(s) before the start of the export; "
                + "it was held at the start instead")
        return note.with(tick: 0)
    }

    /// Lay renderings end to end in pattern order, aligned across tracks.
    ///
    /// A pattern occupies the longest length any track gives it, so tracks of unequal length stay
    /// aligned at every pattern boundary instead of drifting.
    ///
    /// `repeat` lays the whole arrangement down again that many times, every track shifted by the
    /// same cycle so pattern N still starts together on all of them. It is not `passes`: that is
    /// the device's own step-skip cycle inside a pattern, while this exists only in the exported
    /// file.
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

        // Python groups into a dict and then iterates it, so the MIDI track order is the order the
        // names were first seen. A Swift Dictionary has no such order, hence the parallel array.
        var names: [String] = []
        var groups: [String: [RenderedNote]] = [:]
        let ordered = renderings.stableSorted { left, right in
            (left.trackNumber, left.kind == .drum ? 1 : 0, left.patternNumber)
                < (right.trackNumber, right.kind == .drum ? 1 : 0, right.patternNumber)
        }
        // A repeat is placed, not copied afterwards: every round goes through the same offset
        // arithmetic, so a note held past the end of one round is seen against the round that
        // follows it rather than colliding with its own copy.
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

    /// Say so when the tracks do not add up to the same length.
    ///
    /// This export restarts every track at each pattern boundary; the device loops each track
    /// independently, so from the first mismatch onwards the hardware and the file no longer agree
    /// about what plays together.
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
        // Two note-ons for one pitch with one note-off between them hangs in most DAWs. The device
        // retriggers, so the earlier note is shortened instead.
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

/// Two integers as one hashable key, standing in for Python's tuple.
struct Pair: Hashable {
    let first: Int
    let second: Int

    init(_ first: Int, _ second: Int) {
        self.first = first
        self.second = second
    }
}

// MARK: - Layer 3: the only SwiftMIDIFile caller

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

    /// `mido.bpm2tempo`: microseconds per quarter note, **rounded**.
    ///
    /// Not `SwiftMIDIFile`'s own `tempo(bpm:)`, which computes `(60 / bpm) * 1_000_000` and then
    /// truncates with `UInt32(_:)`. mido rounds `60 * 1e6 / bpm`, and the device stores BPM to two
    /// decimal places, so a tempo landing just under a whole microsecond would be written one
    /// lower there and one higher here -- a difference of one byte in the file and none in the
    /// music, but the harness compares events and would rightly call it.
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

        // A DAW shows these on its marker ruler, which is what makes cutting a merged export exact
        // rather than by eye.
        var previousTick = 0
        for boundary in boundaries {
            track.events.append(
                .text(
                    delta: .ticks(UInt32(boundary.tick - previousTick)), type: .marker,
                    string: boundary.markerText))
            previousTick = boundary.tick
        }
        // End-of-track sits at the end of the last pattern rather than the last note, so a DAW
        // sees the arrangement's real length.
        track.deltaTimeBeforeEndOfTrack = .ticks(UInt32(totalTicks - previousTick))
        return track
    }

    /// Turn absolute-tick notes into a delta-time MIDI track.
    static func midiTrack(_ arranged: ArrangedTrack) -> MusicalMIDI1File.Track {
        var track = MusicalMIDI1File.Track()
        track.events.append(.text(type: .trackOrSequenceName, string: arranged.name))

        // note_off sorts before note_on at the same tick so that a note retriggering exactly where
        // the previous one ends does not read as a hanging note.
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

// MARK: - Top level

extension MIDIExport {
    /// Render `project` as a single type-1 MIDI file.
    ///
    /// Only patterns holding notes are rendered; narrow with `Project.select` first to pick
    /// tracks or patterns.
    public static func exportProject(_ project: Project, options: ExportOptions? = nil) throws
        -> ExportResult
    {
        let options = try options ?? ExportOptions()
        let renderings = try renderProject(project, options: options)
        return try result(
            arrange(renderings, repeat: options.repeatCount), project: project, options: options)
    }

    /// One file per non-empty (track, pattern), each starting at tick 0.
    ///
    /// Nothing is laid out across patterns, so this is the layout that invents least; the caller
    /// names the files from each result's ``ExportResult/trackNumbers`` and
    /// ``ExportResult/patternNumbers``.
    public static func exportSplit(_ project: Project, options: ExportOptions? = nil) throws
        -> [ExportResult]
    {
        let options = try options ?? ExportOptions()
        var keys: [Pair] = []
        var parts: [Pair: [Rendering]] = [:]
        for rendering in try renderProject(project, options: options) {
            // Track 1 can contribute a melodic *and* a drum rendering under --include-stale; both
            // belong to the same (track, pattern) file.
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

    /// Render every (track, pattern, parameter set) that holds notes and plays.
    ///
    /// Only the set parameter 86 bit 6 selects is exported (spec section 5); the other would be
    /// notes no hardware ever produces.
    ///
    /// An automatic pass count is resolved across each pattern *column* rather than per rendering,
    /// so a pattern expanding to four repeats on one track does not leave the same pattern falling
    /// silent on another -- this is what keeps pattern N starting at the same tick on every track.
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
                    // Only when both sets hold notes does the flag have to decide. A pattern
                    // holding just one set is exported whatever the flag says -- the reader
                    // already warns about that disagreement, and dropping real user data over it
                    // would be worse.
                    kinds = [live]
                    let stale = populated.first { $0 != live } ?? live
                    // Carries the counts the reader's own line has, so that line can be dropped
                    // below without losing anything.
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
                // The reader says the same pattern holds both sets. This says that *and* which
                // flag brings the other one back, so its duplicate is dropped rather than printed
                // alongside.
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
        // The per-pattern value takes precedence on the device (T7.6), so the global is reported
        // rather than folded in -- the export is not dropping groove here, it is doing what the
        // hardware does.
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
