import Foundation
import KSPKit
import SwiftMIDIFile

/// Building a project from a Standard MIDI file -- a port of `src/ksp/midi_import.py`.
///
/// The inverse of ``MIDIExport``, and a much narrower operation than it looks. The key set of a
/// `.KeyStepPro` file is fixed (spec section 2), so nothing here *creates* a project: a template is
/// loaded and values are overwritten in it. Placement itself is `Mutate.placeNote` and
/// `Mutate.placeDrumNote`.
///
/// Three layers, mirroring the export direction inverted: ``readSong`` (the only part that knows
/// what `SwiftMIDIFile` is) -> ``planSong`` (plain arithmetic) -> ``apply`` (a raw project).
public enum MIDIImport {
    /// MIDI's own default when a file carries no `set_tempo`: 500,000 microseconds per beat.
    public static let defaultTempo = 500_000

    /// MIDI's default when a file carries no `time_signature`.
    public static let defaultTimeSignature = (numerator: 4, denominator: 4)

    /// The MIDI channel GM reserves for percussion, counting from 0.
    public static let drumChannel = 9

    /// No swing. Both the bottom of the device's range and its default.
    static let straight = Constants.swingRangePercent.min

    /// Notes that must land on delayed steps before a groove is believed rather than left to
    /// per-note time shift.
    static let minSwungNotes = 3
}

/// Everything the MIDI file cannot tell us about the target project.
public struct ImportOptions: Sendable, Hashable {
    /// Step size to quantise to. Unlike the export direction, which reads the pattern's own setting
    /// out of `99`, this is a real choice: it decides what grid the incoming clip is snapped to.
    public let stepsPerBeat: Int

    /// Read only this track of the source file, counting from 1.
    public let midiTrack: Int?

    /// Which source track to write as drums, counting from 1.
    public let drumTrack: Int?

    /// The lane-to-note map to invert. `nil` fits a chromatic one to the source's own pitches,
    /// because the real map is device state the file does not carry (spec 3.2.1).
    public let drumMap: DrumMap?

    public let carryTempo: Bool
    public let fitSwing: Bool
    public let fitTimeShift: Bool

    public init(
        stepsPerBeat: Int = Constants.defaultStepsPerBeat,
        midiTrack: Int? = nil,
        drumTrack: Int? = nil,
        drumMap: DrumMap? = nil,
        carryTempo: Bool = true,
        fitSwing: Bool = true,
        fitTimeShift: Bool = true
    ) throws {
        try Constants.checkStepsPerBeat(stepsPerBeat)
        for (name, value) in [("midi_track", midiTrack), ("drum_track", drumTrack)] {
            if let value, value < 1 {
                throw KSPError.value("\(name) counts from 1")
            }
        }
        self.stepsPerBeat = stepsPerBeat
        self.midiTrack = midiTrack
        self.drumTrack = drumTrack
        self.drumMap = drumMap
        self.carryTempo = carryTempo
        self.fitSwing = fitSwing
        self.fitTimeShift = fitTimeShift
    }
}

/// One source track's note events, in ticks. No MIDI library involved.
public struct Clip: Sendable, Hashable {
    public let notes: [RenderedNote]
    public let ticksPerBeat: Int
    public let tempoBPM: Double

    /// Which tracks of the file the notes came from, counting from 1.
    public let sourceTracks: [Int]

    public init(
        notes: [RenderedNote], ticksPerBeat: Int, tempoBPM: Double, sourceTracks: [Int]
    ) {
        self.notes = notes
        self.ticksPerBeat = ticksPerBeat
        self.tempoBPM = tempoBPM
        self.sourceTracks = sourceTracks
    }

    public var channels: [Int] { Set(notes.map(\.channel)).sorted() }

    /// Whether every note sits on the GM percussion channel.
    public var isPercussion: Bool { !notes.isEmpty && channels == [MIDIImport.drumChannel] }
}

/// A whole source file: one clip per note-bearing track, plus its timing.
public struct Song: Sendable, Hashable {
    public let clips: [Clip]
    public let ticksPerBeat: Int
    public let tempoBPM: Double
    public let beatsPerBar: Double
    public let tempoChanges: Int

    /// Events the device cannot store, counted across every track read.
    public let controllersDropped: Int

    public init(
        clips: [Clip], ticksPerBeat: Int, tempoBPM: Double, beatsPerBar: Double,
        tempoChanges: Int = 0, controllersDropped: Int = 0
    ) {
        self.clips = clips
        self.ticksPerBeat = ticksPerBeat
        self.tempoBPM = tempoBPM
        self.beatsPerBar = beatsPerBar
        self.tempoChanges = tempoChanges
        self.controllersDropped = controllersDropped
    }

    public func stepsPerBar(_ stepsPerBeat: Int) -> Int {
        max(1, Arithmetic.pyRound(beatsPerBar * Double(stepsPerBeat)))
    }
}

/// One note addressed the way the device stores it: a 1-based step.
public struct PlacedNote: Sendable, Hashable {
    public let step: Int
    public let pitch: Int
    public let velocity: Int
    public let gate: Int
    public let timeShift: Int

    /// The drum lane this hit plays, or `nil` on a melodic note. A drum note stores a lane index in
    /// `117` where a melodic one stores a pitch.
    public let lane: Int?

    public init(
        step: Int, pitch: Int, velocity: Int, gate: Int = Constants.defaultGateStored,
        timeShift: Int = Constants.timeShiftCentre, lane: Int? = nil
    ) {
        self.step = step
        self.pitch = pitch
        self.velocity = velocity
        self.gate = gate
        self.timeShift = timeShift
        self.lane = lane
    }
}

/// What one pattern holds.
public struct Placement: Sendable, Hashable {
    public let notes: [PlacedNote]
    public let stepCount: Int

    /// The grid the notes were snapped to. Carried so ``MIDIImport/apply(_:plan:)`` can write it
    /// into the pattern's own step size rather than leaving the device to play a 1/32 clip at 1/16.
    public let stepsPerBeat: Int
    public let pattern: Int
    public let swingPercent: Int
    public let diagnostics: Report

    public init(
        notes: [PlacedNote], stepCount: Int,
        stepsPerBeat: Int = Constants.defaultStepsPerBeat, pattern: Int = 1,
        swingPercent: Int = Constants.swingRangePercent.min, diagnostics: Report = Report()
    ) {
        self.notes = notes
        self.stepCount = stepCount
        self.stepsPerBeat = stepsPerBeat
        self.pattern = pattern
        self.swingPercent = swingPercent
        self.diagnostics = diagnostics
    }
}

/// One source track's worth of patterns, and where they go.
public struct TrackPlan: Sendable, Hashable {
    /// The device track, 1-4.
    public let track: Int
    public let placements: [Placement]
    public let isDrum: Bool
    public let sourceTrack: Int?

    public init(
        track: Int, placements: [Placement], isDrum: Bool = false, sourceTrack: Int? = nil
    ) {
        self.track = track
        self.placements = placements
        self.isDrum = isDrum
        self.sourceTrack = sourceTrack
    }

    public var notes: [PlacedNote] { placements.flatMap(\.notes) }
    public var patterns: [Int] { placements.map(\.pattern) }
}

/// Everything the conversion decided, before any of it is written.
public struct SongPlan: Sendable, Hashable {
    public let tracks: [TrackPlan]

    /// The tempo to write, or `nil` to keep the template's.
    public let tempoBPM: Double?
    public let drumMap: DrumMap?
    public let scene: Int
    public let diagnostics: Report

    public init(
        tracks: [TrackPlan], tempoBPM: Double? = nil, drumMap: DrumMap? = nil, scene: Int = 1,
        diagnostics: Report = Report()
    ) {
        self.tracks = tracks
        self.tempoBPM = tempoBPM
        self.drumMap = drumMap
        self.scene = scene
        self.diagnostics = diagnostics
    }

    public var notes: [PlacedNote] { tracks.flatMap(\.notes) }
}

/// A project with the source written into it, ready to serialise.
public struct ImportResult: Sendable {
    public let raw: RawProject
    public let plan: SongPlan
    public let diagnostics: Report

    public init(raw: RawProject, plan: SongPlan, diagnostics: Report) {
        self.raw = raw
        self.plan = plan
        self.diagnostics = diagnostics
    }

    public var notes: [PlacedNote] { plan.notes }
    public var noteCount: Int { plan.notes.count }

    /// The first device track written. The single-target path has one.
    public var track: Int { plan.tracks.first?.track ?? 1 }
    public var pattern: Int { plan.tracks.first?.placements.first?.pattern ?? 1 }
    public var stepCount: Int { plan.tracks.first?.placements.first?.stepCount ?? 0 }
}

// MARK: - Layer 1: reading MIDI

/// One source track's notes, and what else went past while pairing them.
struct TrackRead {
    var notes: [RenderedNote]

    /// Events the device cannot store: controllers, bend, program, pressure.
    var dropped: Int
}

extension MIDIImport {
    /// Pair one track's note-ons with their note-offs, in absolute ticks.
    static func trackNotes(_ track: MusicalMIDI1File.Track, timebase: MusicalMIDIFileTimebase)
        -> TrackRead
    {
        var tick = 0
        var dropped = 0
        var notes: [RenderedNote] = []
        // (channel, pitch) -> (onset tick, velocity). A second note-on for a pitch already
        // sounding retriggers it, so the earlier one ends here. The insertion order is kept
        // alongside, because Python iterates the leftovers in it when closing them.
        var openOrder: [Pair] = []
        var openNotes: [Pair: (onset: Int, velocity: Int)] = [:]

        for event in track.events {
            tick += Int(event.delta.ticks(using: timebase))
            let channel: Int
            let pitch: Int
            let velocity: Int
            let ending: Bool
            switch event.event {
            case .noteOn(let on):
                channel = Int(on.channel)
                pitch = Int(on.note.number)
                velocity = Int(on.velocity.midi1Value)
                ending = velocity == 0
            case .noteOff(let off):
                channel = Int(off.channel)
                pitch = Int(off.note.number)
                velocity = Int(off.velocity.midi1Value)
                ending = true
            case .cc, .pitchBend, .programChange, .pressure, .notePressure, .sysEx7,
                .universalSysEx7:
                dropped += 1
                continue
            default:
                continue
            }

            let held = Pair(channel, pitch)
            if let open = openNotes[held] {
                openNotes[held] = nil
                openOrder.removeAll { $0 == held }
                notes.append(
                    RenderedNote(
                        tick: open.onset, durationTicks: tick - open.onset, pitch: pitch,
                        velocity: open.velocity, channel: channel))
            }
            if !ending {
                openNotes[held] = (tick, velocity)
                openOrder.append(held)
            }
        }

        // A note-on the file never closes still sounded; end it at the track's last event rather
        // than discarding it.
        for held in openOrder {
            guard let open = openNotes[held] else { continue }
            notes.append(
                RenderedNote(
                    tick: open.onset, durationTicks: max(0, tick - open.onset),
                    pitch: held.second, velocity: open.velocity, channel: held.first))
        }

        return TrackRead(notes: notes, dropped: dropped)
    }

    /// Refuse the file shape whose ticks mean something else entirely.
    ///
    /// A timecode file converts to nonsense rather than to nothing, which is the reason to stop
    /// here; a type 2 file holds independent sequences rather than one arrangement.
    static func checkReadable(_ midi: MusicalMIDI1File) throws {
        if midi.timebase.ticksPerQuarterNote < 1 {
            throw KSPError.value(
                "the file is timed in SMPTE timecode rather than ticks per beat, which has no "
                    + "beat to quantise against; re-export it with a PPQ division")
        }
        if midi.format == .multipleTracksAsynchronous {
            throw KSPError.value(
                "a type 2 file holds independent sequences rather than one arrangement, so its "
                    + "tracks cannot be played together; pick one with --midi-track")
        }
    }

    /// The file's first tempo, its first time signature and how many tempi.
    static func timing(_ midi: MusicalMIDI1File) -> (
        tempo: Int, signature: (numerator: Int, denominator: Int), changes: Int
    ) {
        var tempo = defaultTempo
        var signature = defaultTimeSignature
        var changes = 0
        var foundTempo = false
        var foundSignature = false

        for track in midi.tracks {
            for event in track.events {
                switch event.event {
                case .tempo(let any):
                    changes += 1
                    if !foundTempo {
                        tempo = Int(any.microsecondsPerQuarter)
                        foundTempo = true
                    }
                case .timeSignature(let sig):
                    if !foundSignature {
                        // The file stores the denominator as a power of two; mido reports the
                        // denominator itself, and every arithmetic use here expects mido's.
                        signature = (Int(sig.numerator), 1 << Int(sig.denominator))
                        foundSignature = true
                    }
                default:
                    break
                }
            }
        }
        return (tempo, signature, changes)
    }

    /// `mido.tempo2bpm` at the default 4/4: microseconds per beat back to BPM.
    static func tempoToBPM(_ tempo: Int) -> Double {
        60 * 1_000_000 / Double(tempo)
    }

    /// Every selected track's notes, merged into one clip in absolute ticks.
    public static func readClip(_ midi: MusicalMIDI1File, options: ImportOptions? = nil) throws
        -> Clip
    {
        let options = try options ?? ImportOptions()
        try checkReadable(midi)
        let (tempo, _, _) = timing(midi)

        var notes: [RenderedNote] = []
        var sources: [Int] = []
        for (index, track) in midi.tracks.enumerated() {
            let number = index + 1
            if let only = options.midiTrack, number != only { continue }
            let found = trackNotes(track, timebase: midi.timebase).notes
            if !found.isEmpty {
                sources.append(number)
                notes.append(contentsOf: found)
            }
        }

        return Clip(
            notes: notes.stableSorted { ($0.tick, $0.pitch) < ($1.tick, $1.pitch) },
            ticksPerBeat: Int(midi.timebase.ticksPerQuarterNote),
            tempoBPM: tempoToBPM(tempo),
            sourceTracks: sources)
    }

    /// One clip per note-bearing source track and channel, in file order.
    ///
    /// Type 1 files -- what a DAW exports -- give one track per instrument. A type 0 file puts
    /// everything on one track and tells its instruments apart by channel alone, so a track
    /// carrying several is split into one clip each: merged, its percussion would arrive as melodic
    /// pitches on whichever device track the rest of it landed on.
    public static func readSong(_ midi: MusicalMIDI1File, options: ImportOptions? = nil) throws
        -> Song
    {
        let options = try options ?? ImportOptions()
        try checkReadable(midi)
        let (tempo, signature, changes) = timing(midi)
        let tempoBPM = tempoToBPM(tempo)

        var clips: [Clip] = []
        var dropped = 0
        for (index, track) in midi.tracks.enumerated() {
            let number = index + 1
            if let only = options.midiTrack, number != only { continue }
            let read = trackNotes(track, timebase: midi.timebase)
            dropped += read.dropped
            var byChannel: [Int: [RenderedNote]] = [:]
            for note in read.notes {
                byChannel[note.channel, default: []].append(note)
            }
            for channel in byChannel.keys.sorted() {
                let notes = (byChannel[channel] ?? []).stableSorted {
                    ($0.tick, $0.pitch) < ($1.tick, $1.pitch)
                }
                clips.append(
                    Clip(
                        notes: notes, ticksPerBeat: Int(midi.timebase.ticksPerQuarterNote),
                        tempoBPM: tempoBPM, sourceTracks: [number]))
            }
        }

        return Song(
            clips: clips,
            ticksPerBeat: Int(midi.timebase.ticksPerQuarterNote),
            tempoBPM: tempoBPM,
            // A bar in quarter notes, which is what a beat is here.
            beatsPerBar: Double(signature.numerator) * 4 / Double(signature.denominator),
            tempoChanges: changes,
            controllersDropped: dropped)
    }
}

// MARK: - Layer 2: planning

/// One source note against the grid, before it belongs to a pattern.
struct Snapped {
    /// 0-based, counted from the anchored origin, and unbounded by a pattern.
    let step: Int

    /// Ticks between where the note actually is and where its step is.
    let residual: Double

    let note: RenderedNote
}

extension MIDIImport {
    /// The tick the first note of `clips` is snapped back from.
    ///
    /// Taken across every clip at once on the whole-file path. Anchoring each track on its own
    /// first note would slide a part that enters at bar 3 back onto bar 1, which is not a lead-in
    /// the pattern cannot hold -- it is the arrangement.
    static func anchor(_ clips: [Clip], _ ticksPerStep: Double) -> Double {
        let first = clips.flatMap(\.notes).map(\.tick).min() ?? 0
        return Double(Arithmetic.pyRound(Double(first) / ticksPerStep)) * ticksPerStep
    }

    /// The step `offset` belongs to under `percent` swing, and what is left.
    ///
    /// Nearest-step arithmetic alone cannot do this. At 75% -- the device's maximum -- a delayed
    /// step sits exactly half a step late, so snapping to the nearest lands it on the *next* step
    /// and collapses each pair onto one. So the neighbours are tried against the swung grid and
    /// the closest wins.
    static func assignStep(_ offset: Double, _ ticksPerStep: Double, _ percent: Int) -> (
        step: Int, residual: Double
    ) {
        let base = Arithmetic.pyRound(offset / ticksPerStep)
        var best: (step: Int, residual: Double)?
        for step in [base - 1, base, base + 1] {
            if step < 0 { continue }
            let residual =
                offset
                - (Double(step) * ticksPerStep + MIDIExport.swingDelay(step, percent, ticksPerStep))
            if best == nil || abs(residual) < abs(best?.residual ?? 0) {
                best = (step, residual)
            }
        }
        return best ?? (0, offset)
    }

    static func snap(_ clip: Clip, _ ticksPerStep: Double, _ origin: Double, _ percent: Int)
        -> [Snapped]
    {
        clip.notes
            .stableSorted { ($0.tick, $0.pitch) < ($1.tick, $1.pitch) }
            .map { note in
                let (step, residual) = assignStep(
                    Double(note.tick) - origin, ticksPerStep, percent)
                return Snapped(step: step, residual: residual, note: note)
            }
    }

    /// The swing percentage that best explains a clip's timing.
    ///
    /// Fitted before any time shift is spent, because one pattern-level value expresses a
    /// systematic groove for free and the per-note field is scarce (Timing_Calibration 3.2). A
    /// search over the 26 storable percentages, not an inverted median -- see ROADMAP M6 for why
    /// the median breaks at 75 %. Ties keep the lowest, so a straight clip stays straight.
    static func fitSwing(_ clip: Clip, _ ticksPerStep: Double, _ origin: Double) -> Int {
        let (low, high) = Constants.swingRangePercent
        if clip.notes.isEmpty { return low }

        let offsets = clip.notes.map { Double($0.tick) - origin }
        var bestPercent = low
        var bestCost = Double.infinity
        for percent in low...high {
            let cost = offsets.reduce(0.0) {
                $0 + abs(assignStep($1, ticksPerStep, percent).residual)
            }
            // The epsilon is what makes the *lowest* percent win a tie, so an unswung source
            // stays straight rather than picking up whichever percentage floating point favoured.
            if cost < bestCost - 1e-9 {
                bestPercent = percent
                bestCost = cost
            }
        }

        if bestPercent == low { return low }

        // A groove is a thing a pattern does repeatedly. Without that guard the search will gladly
        // explain one late note as swing, which would displace every other note on a delayed step
        // to explain a single one.
        let swung = offsets.filter {
            Arithmetic.floorMod(assignStep($0, ticksPerStep, bestPercent).step, 2) != 0
        }.count
        return swung >= minSwungNotes ? bestPercent : low
    }

    /// A residual as a stored time shift, and what it could not express.
    ///
    /// The unit is a fixed 1/400 of a beat (spec 6.4), so the reachable range is 60 ticks either
    /// way at 480 PPQN whatever the step size.
    static func fitShift(_ residual: Double, _ ticksPerBeat: Int) -> (
        stored: Int, remainder: Double
    ) {
        let unit = Double(ticksPerBeat) / Double(Constants.timeShiftUnitsPerBeat)
        let (low, high) = Constants.timeShiftRange
        let wanted = residual / unit
        let units = max(low, min(high, Arithmetic.pyRound(wanted)))
        return (Constants.timeShiftCentre + units, residual - Double(units) * unit)
    }

    /// The ladder rung nearest this note's length, and whether it is exact.
    static func gateFor(_ note: RenderedNote, _ ticksPerStep: Double) -> (stored: Int, exact: Bool)
    {
        let length = Double(note.durationTicks) / ticksPerStep
        let stored = Constants.encodeGate(length)
        return (stored, Constants.gateTable[stored] == length)
    }

    /// Turn snapped notes into one pattern's worth of placed ones.
    ///
    /// `offset` is the 0-based step this pattern starts at within the track, so a split track's
    /// later patterns count their steps from 1 again. `swing` is already fitted and already removed
    /// from each residual, so what is left here is only what time shift has to carry.
    static func place(
        _ snapped: [Snapped], stepCount: Int, pattern: Int, ticksPerStep: Double,
        ticksPerBeat: Int, options: ImportOptions, drumMap: DrumMap?, site: Site,
        collector: Collector, swing: Int, offset: Int = 0
    ) throws -> Placement {
        var notes: [PlacedNote] = []
        var approximated = 0
        var heldPastEnd = 0
        var unrepresentable = 0
        var unmapped: [Int] = []

        for entry in snapped {
            let local = entry.step - offset
            let (gate, exact) = gateFor(entry.note, ticksPerStep)
            if !exact { approximated += 1 }
            if Double(local) + Double(entry.note.durationTicks) / ticksPerStep > Double(stepCount) {
                heldPastEnd += 1
            }

            var shift = Constants.timeShiftCentre
            if options.fitTimeShift {
                let fitted = fitShift(entry.residual, ticksPerBeat)
                shift = fitted.stored
                if abs(fitted.remainder)
                    > Double(ticksPerBeat) / Double(Constants.timeShiftUnitsPerBeat) / 2
                {
                    unrepresentable += 1
                }
            }

            var lane: Int?
            if let drumMap {
                lane = drumMap.laneForNote(entry.note.pitch)
                if lane == nil {
                    unmapped.append(entry.note.pitch)
                    continue
                }
            }

            notes.append(
                PlacedNote(
                    step: local + 1, pitch: entry.note.pitch, velocity: entry.note.velocity,
                    gate: gate, timeShift: shift, lane: lane))
        }

        if swing != Constants.swingRangePercent.min {
            collector.add(
                .swingFitted,
                "the source swings; pattern \(pattern) was written at \(swing)% swing and each "
                    + "note's leftover given to its time shift",
                site: site)
        }
        if approximated > 0 {
            collector.add(
                .gateApproximated,
                "\(approximated) note length(s) are not on the gate ladder and took the nearest "
                    + "rung; the ladder is coarse above 3 steps",
                site: site, subjects: approximated)
        }
        if heldPastEnd > 0 {
            collector.add(
                .gatePastEnd,
                "\(heldPastEnd) note(s) are held past step \(stepCount); the device loops the "
                    + "pattern rather than sustaining them",
                site: site, subjects: heldPastEnd)
        }
        if unrepresentable > 0 {
            collector.add(
                .timingResidual,
                "\(unrepresentable) note(s) sit further off the grid than swing and time shift "
                    + "together reach, and were left at the nearest position the device can store",
                site: site, subjects: unrepresentable)
        }
        if !unmapped.isEmpty {
            collector.add(
                .drumPitchUnmapped,
                "\(unmapped.count) note(s) at pitch(es) \(listed(Set(unmapped).sorted())) are "
                    + "outside the drum map's 24 lanes and were dropped",
                site: site, subjects: unmapped.count)
        }

        // Refused here rather than by `Mutate` from underneath, so the message can name the step to
        // thin and nothing has been written yet.
        var crowded: [Int: Int] = [:]
        for note in notes {
            crowded[note.step, default: 0] += 1
        }
        let over = crowded.filter { $0.value > Constants.maxNotesPerStep }.map(\.key)
        if !over.isEmpty {
            // The worst step, and the earliest of those when several tie.
            let step = over.max { left, right in
                (crowded[left] ?? 0, -left) < (crowded[right] ?? 0, -right)
            }
            let held = crowded[step ?? 0] ?? 0
            let location = site.track.map { "track \($0) " } ?? ""
            throw KSPError.value(
                "step \(step ?? 0) of \(location)pattern \(pattern) holds \(held) notes; the "
                    + "firmware's limit is \(Constants.maxNotesPerStep) per step. Thin the chord, "
                    + "or quantise finer with --steps-per-beat so its notes fall on steps of "
                    + "their own")
        }

        if notes.count > Constants.poolCapacity {
            collector.add(
                .poolOverflow,
                "pattern \(pattern) holds \(notes.count) events; the firmware's limit is "
                    + "\(Constants.poolCapacity), so the last "
                    + "\(notes.count - Constants.poolCapacity) were dropped",
                site: site, subjects: notes.count - Constants.poolCapacity)
            notes = Array(notes.prefix(Constants.poolCapacity))
        }

        return Placement(
            notes: notes, stepCount: stepCount, stepsPerBeat: options.stepsPerBeat,
            pattern: pattern, swingPercent: swing)
    }

    /// Snap `clip` to a `stepCount`-step grid, as one pattern.
    ///
    /// The single-target path: notes past the last step are dropped, because the device disables
    /// them rather than playing them. ``planTrack`` is the one that splits instead.
    public static func quantise(_ clip: Clip, stepCount: Int, options: ImportOptions? = nil) throws
        -> Placement
    {
        let options = try options ?? ImportOptions()
        guard 1...Constants.maxSteps ~= stepCount else {
            throw KSPError.value("step count \(stepCount) out of range 1-\(Constants.maxSteps)")
        }

        let collector = Collector()
        let ticksPerStep = Double(clip.ticksPerBeat) / Double(options.stepsPerBeat)
        let origin = anchor([clip], ticksPerStep)

        if clip.sourceTracks.count > 1 || clip.channels.count > 1 {
            collector.add(
                .multipleSources,
                "notes came from track(s) \(listed(clip.sourceTracks)) and channel(s) "
                    + "\(listed(clip.channels.map { $0 + 1 })) and were merged into one pattern; "
                    + "--midi-track picks just one")
        }
        if origin != 0 {
            collector.add(
                .clipAnchored,
                "the clip starts \(Arithmetic.general(origin)) tick(s) into the file; its first "
                    + "note was placed on step 1 and the rest moved with it, because a pattern is "
                    + "a loop with nowhere to keep a lead-in")
        }

        let swing = options.fitSwing ? fitSwing(clip, ticksPerStep, origin) : straight
        let snapped = snap(clip, ticksPerStep, origin, swing)
        let moved = snapped.filter { $0.residual != 0 }.count
        if moved > 0 {
            collector.add(
                .notesQuantised,
                "\(moved) note(s) did not land on a 1/\(options.stepsPerBeat * 4) step and were "
                    + "moved to the nearest one",
                subjects: moved)
        }

        let within = snapped.filter { 0 <= $0.step && $0.step < stepCount }
        let dropped = snapped.count - within.count
        if dropped > 0 {
            collector.add(
                .pastPatternEnd,
                "\(dropped) note(s) fall past step \(stepCount) and were dropped; the device "
                    + "disables notes past the last step rather than playing them",
                subjects: dropped)
        }

        let placement = try place(
            within, stepCount: stepCount, pattern: 1, ticksPerStep: ticksPerStep,
            ticksPerBeat: clip.ticksPerBeat, options: options, drumMap: nil, site: Site(),
            collector: collector, swing: swing)
        return Placement(
            notes: placement.notes, stepCount: placement.stepCount,
            stepsPerBeat: placement.stepsPerBeat, pattern: placement.pattern,
            swingPercent: placement.swingPercent, diagnostics: collector.report())
    }

    /// Lay one source track out across as many patterns as it needs.
    ///
    /// The track's length is its content rounded up to a whole bar, then cut into 64-step patterns
    /// -- the device's ceiling. Nothing is truncated: a sequence too long for one pattern becomes
    /// several, chained. Lengths are per track, not padded to a common one: the device loops each
    /// track's chain on its own, so a one-bar part under an eight-bar one repeats against it.
    public static func planTrack(
        _ clip: Clip, track: Int, collector: Collector, options: ImportOptions? = nil,
        isDrum: Bool = false, drumMap: DrumMap? = nil, firstPattern: Int = 1,
        stepsPerBar: Int = 16, origin: Double
    ) throws -> TrackPlan {
        let options = try options ?? ImportOptions()
        let ticksPerStep = Double(clip.ticksPerBeat) / Double(options.stepsPerBeat)
        let site = Site(track: track, kind: isDrum ? "drum" : "seq")

        // Fitted once for the track rather than once per pattern: a groove belongs to the
        // performance, not to which 64-step window of it a pattern holds, and the steps a pattern
        // is cut on cannot be known until it is fitted.
        let swing = options.fitSwing ? fitSwing(clip, ticksPerStep, origin) : straight
        let snapped = snap(clip, ticksPerStep, origin, swing)

        // The last step any note reaches, rounded up to the bar so a loop stays musical: a track
        // that stops mid-bar drifts against every other one.
        let ends = snapped.map {
            Double($0.step) + Double($0.note.durationTicks) / ticksPerStep
        }
        let furthest = Arithmetic.pyRound(ends.max() ?? 1)
        let total = max(1, Arithmetic.ceilDiv(furthest, stepsPerBar) * stepsPerBar)

        let moved = snapped.filter { $0.residual != 0 }.count
        if moved > 0 {
            collector.add(
                .notesQuantised,
                "\(moved) note(s) on track \(track) did not land on a "
                    + "1/\(options.stepsPerBeat * 4) step and were moved to the nearest one",
                site: site, subjects: moved)
        }

        var count = Arithmetic.ceilDiv(total, Constants.maxSteps)
        let available = Constants.patternsPerTrack - firstPattern + 1
        if count > available {
            collector.add(
                .pastPatternEnd,
                "track \(track) needs \(count) patterns but only \(available) are free from "
                    + "pattern \(firstPattern); the tail was dropped",
                site: site, subjects: count - available)
            count = available
        }

        var placements: [Placement] = []
        for index in 0..<max(0, count) {
            let offset = index * Constants.maxSteps
            let steps = min(Constants.maxSteps, total - offset)
            let inside = snapped.filter { offset <= $0.step && $0.step < offset + steps }
            placements.append(
                try place(
                    inside, stepCount: steps, pattern: firstPattern + index,
                    ticksPerStep: ticksPerStep, ticksPerBeat: clip.ticksPerBeat, options: options,
                    drumMap: isDrum ? drumMap : nil,
                    site: Site(track: track, pattern: firstPattern + index, kind: site.kind),
                    collector: collector, swing: swing, offset: offset))
        }

        if count > 1 {
            collector.add(
                .patternSplit,
                "track \(track) runs \(total) steps, past the device's \(Constants.maxSteps); it "
                    + "was split across patterns \(firstPattern)-\(firstPattern + count - 1) and "
                    + "chained",
                site: site)
        }

        return TrackPlan(
            track: track, placements: placements, isDrum: isDrum,
            sourceTrack: clip.sourceTracks.first)
    }

    /// A chromatic map covering `clip`'s pitches, low note first.
    ///
    /// The device's real map is a global setting the project file does not carry (spec 3.2.1), so
    /// importing drums means assuming one. Assuming the factory default would silently drop every
    /// source that does not start at MIDI 36, which is most of them; fitting to what is actually
    /// there converts the file and says which map it used.
    public static func fitDrumMap(_ clip: Clip) throws -> DrumMap {
        let low = clip.notes.map(\.pitch).min() ?? DrumMap.defaultChromaticLow
        return try DrumMap.chromatic(max(DrumMap.minNote, min(low, DrumMap.maxChromaticLow)))
    }

    /// Several clips of one source track back into the one the file wrote.
    static func merged(_ clips: [Clip]) -> Clip {
        guard let first = clips.first else {
            return Clip(notes: [], ticksPerBeat: 1, tempoBPM: 120, sourceTracks: [])
        }
        if clips.count == 1 { return first }
        let notes = clips.flatMap(\.notes).stableSorted {
            ($0.tick, $0.pitch) < ($1.tick, $1.pitch)
        }
        return Clip(
            notes: notes, ticksPerBeat: first.ticksPerBeat, tempoBPM: first.tempoBPM,
            sourceTracks: first.sourceTracks)
    }

    /// Which device track each source clip goes to, and which one is drums.
    ///
    /// Melodic clips fill the tracks from `firstTrack` upwards in source order. A drum clip goes to
    /// Track 1 whatever that is, because item 123 is the only one carrying a drum parameter set.
    static func assign(
        _ song: Song, _ options: ImportOptions, _ collector: Collector, _ firstTrack: Int = 1
    ) throws -> [(clip: Clip, track: Int, isDrum: Bool)] {
        var drum: Clip?
        var melodic: [Clip]
        if let named = options.drumTrack {
            // --drum-track names a track of the file, so a track split across channels is put back
            // together rather than leaving half a kit behind.
            let matching = song.clips.filter { $0.sourceTracks == [named] }
            if matching.isEmpty {
                throw KSPError.value(
                    "track \(named) of the source holds no notes; --drum-track counts every track "
                        + "of the file from 1, including ones that carry only tempo or a name")
            }
            drum = merged(matching)
            melodic = song.clips.filter { $0.sourceTracks != [named] }
        } else {
            let found = song.clips.firstIndex { $0.isPercussion }
            drum = found.map { song.clips[$0] }
            melodic = song.clips.enumerated().filter { $0.offset != found }.map(\.element)
        }

        var assigned: [(clip: Clip, track: Int, isDrum: Bool)] = []
        if let drum {
            assigned.append((drum, 1, true))
        }

        // Only Track 1 carries a drum set, so it is spoken for when there is one.
        let free = (firstTrack...max(firstTrack, Constants.trackItemIDs.count)).filter {
            $0 <= Constants.trackItemIDs.count && (drum == nil || $0 != 1)
        }
        for (clip, track) in zip(melodic, free) {
            assigned.append((clip, track, false))
        }

        let dropped = melodic.count - free.count
        if dropped > 0 {
            collector.add(
                .tracksDropped,
                "\(dropped) source track(s) had nowhere to go; the device has "
                    + "\(Constants.trackItemIDs.count) tracks",
                subjects: dropped)
        }
        return assigned
    }

    /// Decide everything the conversion will write, without writing any of it.
    public static func planSong(
        _ song: Song, options: ImportOptions? = nil, firstPattern: Int = 1, firstTrack: Int = 1,
        scene: Int = 1
    ) throws -> SongPlan {
        let options = try options ?? ImportOptions()
        let collector = Collector()

        var split: [Int: Int] = [:]
        for clip in song.clips {
            guard let source = clip.sourceTracks.first else { continue }
            split[source, default: 0] += 1
        }
        let multi = split.filter { $0.value > 1 }
        if !multi.isEmpty {
            collector.add(
                .trackSplitByChannel,
                "source track(s) \(listed(multi.keys.sorted())) carry more than one channel; each "
                    + "channel became a device track of its own rather than being merged into one "
                    + "part",
                subjects: multi.values.reduce(0, +))
        }
        if song.controllersDropped > 0 {
            collector.add(
                .controllersDropped,
                "\(song.controllersDropped) event(s) are control change, pitch bend, program "
                    + "change or pressure; a pattern stores notes only, so they were dropped",
                subjects: song.controllersDropped)
        }

        let assigned = try assign(song, options, collector, firstTrack)

        var drumMap = options.drumMap
        let drumClip = assigned.first { $0.isDrum }?.clip
        if let drumClip, drumMap == nil {
            let fitted = try fitDrumMap(drumClip)
            drumMap = fitted
            collector.add(
                .drumMapFitted,
                "no drum map was given, so one was fitted to the source: \(fitted.describe()). "
                    + "The real map is a device setting the project file does not carry")
        }

        let stepsPerBar = song.stepsPerBar(options.stepsPerBeat)
        let ticksPerStep = Double(song.ticksPerBeat) / Double(options.stepsPerBeat)
        let origin = anchor(assigned.map(\.clip), ticksPerStep)
        if origin != 0 {
            collector.add(
                .clipAnchored,
                "the song starts \(Arithmetic.general(origin)) tick(s) into the file; every track "
                    + "was moved back together so its first note lands on step 1, because a "
                    + "pattern is a loop with nowhere to keep a lead-in")
        }

        let tracks = try assigned.map {
            try planTrack(
                $0.clip, track: $0.track, collector: collector, options: options,
                isDrum: $0.isDrum, drumMap: drumMap, firstPattern: firstPattern,
                stepsPerBar: stepsPerBar, origin: origin)
        }

        var tempo: Double?
        if options.carryTempo && !song.clips.isEmpty {
            let (low, high) = Constants.tempoRangeBPM
            let clamped = max(low, min(high, song.tempoBPM))
            tempo = clamped
            if clamped != song.tempoBPM {
                collector.add(
                    .tempoOutOfRange,
                    "the source runs at \(Arithmetic.general(song.tempoBPM)) BPM, outside the "
                        + "\(Arithmetic.general(low))-\(Arithmetic.general(high)) the device "
                        + "plays; the project was written at \(Arithmetic.general(clamped)) BPM "
                        + "instead")
            } else {
                collector.add(
                    .tempoCarried,
                    "the project tempo was set to the source's "
                        + "\(Arithmetic.general(song.tempoBPM)) BPM")
            }
            if song.tempoChanges > 1 {
                collector.add(
                    .tempoChangesIgnored,
                    "the source changes tempo \(song.tempoChanges) time(s); the device stores one "
                        + "tempo per project, so \(Arithmetic.general(song.tempoBPM)) BPM was "
                        + "taken and the rest ignored")
            }
        }

        return SongPlan(
            tracks: tracks, tempoBPM: tempo, drumMap: drumMap, scene: scene,
            diagnostics: collector.report())
    }

    static func listed(_ values: [Int]) -> String {
        values.isEmpty ? "none" : values.map(String.init).joined(separator: ", ")
    }
}

// MARK: - Layer 3: writing

extension MIDIImport {
    /// Write `plan` into a copy of `raw`.
    ///
    /// One copy for the whole conversion rather than one per note: the scalars go through the
    /// ordinary `Mutate` functions, and the notes -- of which there may be hundreds -- through the
    /// delta form onto this dictionary.
    public static func apply(_ raw: RawProject, plan: SongPlan) throws -> RawProject {
        var result = raw

        for trackPlan in plan.tracks {
            let track = trackPlan.track
            let drum = trackPlan.isDrum
            result = try Mutate.setDrumMode(result, track: track, on: drum)

            for placement in trackPlan.placements {
                let pattern = placement.pattern
                result = try Mutate.setStepSize(
                    result, track: track, pattern: pattern,
                    stepsPerBeat: placement.stepsPerBeat, drum: drum)
                result = try Mutate.setStepCount(
                    result, track: track, pattern: pattern, steps: placement.stepCount, drum: drum)
                result = try Mutate.setSwing(
                    result, track: track, pattern: pattern, percent: placement.swingPercent,
                    drum: drum)

                for note in placement.notes {
                    let updates: [String: Int]
                    if drum {
                        guard let lane = note.lane else { continue }
                        updates = try Mutate.drumNoteUpdates(
                            result, pattern: pattern, lane: lane, step: note.step,
                            velocity: note.velocity, gate: note.gate, timeShift: note.timeShift)
                    } else {
                        updates = try Mutate.noteUpdates(
                            result, track: track, pattern: pattern, step: note.step,
                            pitch: note.pitch, velocity: note.velocity, gate: note.gate,
                            timeShift: note.timeShift)
                    }
                    try Mutate.mergeUpdates(&result, updates)
                }
            }

            // Only a split track needs a chain. Every sample project leaves all 16 slots at the
            // sentinel and still plays, so a chain is what makes several patterns one sequence --
            // not what makes one pattern play. Writing one anyway would rewrite the scene of a
            // project that was only ever asked to take a clip.
            if trackPlan.placements.count > 1 {
                result = try Mutate.setChain(
                    result, scene: plan.scene, track: track, patterns: trackPlan.patterns)
            }
        }

        if let tempo = plan.tempoBPM {
            result = try Mutate.setTempo(result, bpm: tempo)
        }
        return result
    }

    /// Put a converted project in MCC's key order, with a `version` key.
    ///
    /// The factory template has no `version` and every saved project does, so starting from it
    /// means injecting one. `canonical` places it (spec section 2).
    public static func saveable(_ raw: RawProject) -> [(key: String, value: JSONValue)] {
        var project = raw
        if project["version"] == nil {
            project["version"] = .string(Constants.projectVersion)
        }
        return LenientJSON.canonical(project)
    }

    /// The declared length of one melodic pattern, in steps. `98` is 0-based.
    public static func patternStepCount(_ raw: RawProject, track: Int, pattern: Int) throws -> Int {
        let item = try Keys.itemForTrack(track)
        guard let stored = try Keys.getInt(raw, item, Constants.pSeqStepCount, pattern) else {
            throw KSPError.value("track \(track) pattern \(pattern) declares no step count")
        }
        return stored + Constants.stepCountOffset
    }

    /// Whether a pattern's note pool holds nothing.
    ///
    /// Existence is `50 != 127` -- `54` on the drum side -- and nothing else, never velocity
    /// (spec 4).
    public static func patternIsEmpty(
        _ raw: RawProject, track: Int, pattern: Int, drum: Bool = false
    ) throws -> Bool {
        let item = try Keys.itemForTrack(track)
        let param = drum ? Constants.pDrumNoteStep : Constants.pSeqNoteStep
        for slot in 1...Constants.poolSlots {
            for ordinal in 1...Constants.maxSteps {
                let value = try Keys.getInt(raw, item, param, pattern, slot, ordinal)
                if let value, value != Constants.sentinel { return false }
            }
        }
        return true
    }

    /// Whether a track's mode flag says the melodic parameter set is live.
    ///
    /// `86` bit 6 is DRUM on Track 1 and ARP on Tracks 2-4 (spec 5). Either way the melodic pool is
    /// not what the device is playing from.
    public static func trackIsMelodic(_ raw: RawProject, track: Int) throws -> Bool {
        let item = try Keys.itemForTrack(track)
        let bits = try Keys.getInt(raw, item, Constants.pTrackModeBits) ?? 0
        return bits & (1 << Constants.drumModeBit) == 0
    }

    /// Refuse the whole conversion if any target pattern already holds notes.
    ///
    /// Checked before anything is written, so a file is never left half converted. Appending to an
    /// occupied pool would interleave two takes, and emptying one means writing sentinels, which no
    /// hardware capture covers.
    static func checkTargets(_ raw: RawProject, _ plan: SongPlan) throws {
        for trackPlan in plan.tracks {
            for placement in trackPlan.placements {
                if try !patternIsEmpty(
                    raw, track: trackPlan.track, pattern: placement.pattern,
                    drum: trackPlan.isDrum)
                {
                    let kind = trackPlan.isDrum ? "drum" : "melodic"
                    throw KSPError.value(
                        "track \(trackPlan.track) pattern \(placement.pattern) already holds "
                            + "notes in its \(kind) pool; pick an empty pattern")
                }
            }
        }
    }

    /// Convert one clip of `midi` into one pattern of the template `raw`.
    ///
    /// The single-target path: everything lands on `track` and `pattern`, at the length that
    /// pattern already declares. ``convertSong`` is the one that reads a whole file.
    public static func convert(
        _ midi: MusicalMIDI1File, _ raw: RawProject, track: Int = 1, pattern: Int = 1,
        options: ImportOptions? = nil
    ) throws -> ImportResult {
        let options = try options ?? ImportOptions()
        if try !trackIsMelodic(raw, track: track) {
            throw KSPError.value(
                "track \(track) has parameter 86 bit 6 set, so the device is not playing its "
                    + "melodic notes; pick another track or clear the mode on the device")
        }
        if try !patternIsEmpty(raw, track: track, pattern: pattern) {
            throw KSPError.value(
                "track \(track) pattern \(pattern) already holds notes; pick an empty pattern")
        }

        let clip = try readClip(midi, options: options)
        let placement = try quantise(
            clip, stepCount: patternStepCount(raw, track: track, pattern: pattern),
            options: options)
        let plan = SongPlan(
            tracks: [TrackPlan(track: track, placements: [placement])],
            diagnostics: placement.diagnostics)
        return ImportResult(
            raw: try apply(raw, plan: plan), plan: plan, diagnostics: placement.diagnostics)
    }

    /// Convert every note-bearing track of `midi` into the template `raw`.
    public static func convertSong(
        _ midi: MusicalMIDI1File, _ raw: RawProject, options: ImportOptions? = nil,
        firstPattern: Int = 1, firstTrack: Int = 1
    ) throws -> ImportResult {
        let options = try options ?? ImportOptions()
        let song = try readSong(midi, options: options)
        let scene = try Keys.getInt(raw, Constants.itemProject, Constants.pCurrentScene) ?? 0
        let plan = try planSong(
            song, options: options, firstPattern: firstPattern, firstTrack: firstTrack,
            scene: scene + 1)
        try checkTargets(raw, plan)
        return ImportResult(
            raw: try apply(raw, plan: plan), plan: plan, diagnostics: plan.diagnostics)
    }
}
