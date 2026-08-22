import Foundation
import KSPKit
import SwiftMIDIFile

public enum MIDIImport {
    public static let defaultTempo = 500_000

    public static let defaultTimeSignature = (numerator: 4, denominator: 4)

    public static let drumChannel = 9

    static let straight = Constants.swingRangePercent.min

    static let minSwungNotes = 3
}

public struct TrackRoute: Sendable, Hashable {
    public var source: Int
    public var device: Int

    public init(source: Int, device: Int) {
        self.source = source
        self.device = device
    }
}

public struct ImportOptions: Sendable, Hashable {
    public let stepsPerBeat: Int

    public let midiTracks: Set<Int>

    public let drumTrack: Int?

    public let drumMap: DrumMap?

    public let carryTempo: Bool
    public let fitSwing: Bool
    public let fitTimeShift: Bool

    public let routes: [TrackRoute]

    public init(
        stepsPerBeat: Int = Constants.defaultStepsPerBeat,
        midiTracks: Set<Int> = [],
        drumTrack: Int? = nil,
        drumMap: DrumMap? = nil,
        carryTempo: Bool = true,
        fitSwing: Bool = true,
        fitTimeShift: Bool = true,
        routes: [TrackRoute] = []
    ) throws {
        try Constants.checkStepsPerBeat(stepsPerBeat)
        if midiTracks.contains(where: { $0 < 1 }) {
            throw KSPError.value("midi_track counts from 1")
        }
        if let drumTrack, drumTrack < 1 {
            throw KSPError.value("drum_track counts from 1")
        }
        try ImportOptions.checkRoutes(routes, drumTrack: drumTrack, midiTracks: midiTracks)
        self.stepsPerBeat = stepsPerBeat
        self.midiTracks = midiTracks
        self.drumTrack = drumTrack
        self.drumMap = drumMap
        self.carryTempo = carryTempo
        self.fitSwing = fitSwing
        self.fitTimeShift = fitTimeShift
        self.routes = routes
    }

    private static func checkRoutes(
        _ routes: [TrackRoute], drumTrack: Int?, midiTracks: Set<Int>
    ) throws {
        if !routes.isEmpty && !midiTracks.isEmpty {
            throw KSPError.value(
                "routes and midi_track contradict each other; midi_track converts a single "
                    + "source track into the one pattern the target names, leaving a route "
                    + "nothing to place")
        }
        let tracks = Constants.trackItemIDs.count
        var sources: Set<Int> = []
        var devices: [Int: TrackRoute] = [:]
        for route in routes {
            if route.source < 1 {
                throw KSPError.value(
                    "route counts source tracks from 1, so \(route.source):\(route.device) "
                        + "is not one")
            }
            if route.device < 1 || route.device > tracks {
                throw KSPError.value(
                    "route \(route.source):\(route.device) names device track \(route.device); "
                        + "the device has \(tracks) tracks")
            }
            if sources.contains(route.source) {
                throw KSPError.value("route names source track \(route.source) twice")
            }
            if let first = devices[route.device] {
                throw KSPError.value(
                    "routes \(first.source):\(first.device) and "
                        + "\(route.source):\(route.device) both name device track "
                        + "\(route.device); one device track holds one source track")
            }
            if drumTrack == route.source && route.device != 1 {
                throw KSPError.value(
                    "route \(route.source):\(route.device) sends the drum track to device "
                        + "track \(route.device); only device track 1 carries a drum set")
            }
            if let drumTrack, drumTrack != route.source && route.device == 1 {
                throw KSPError.value(
                    "route \(route.source):1 collides with the drum track; only device track 1 "
                        + "carries a drum set")
            }
            sources.insert(route.source)
            devices[route.device] = route
        }
    }
}

public struct Clip: Sendable, Hashable {
    public let notes: [RenderedNote]
    public let ticksPerBeat: Int
    public let tempoBPM: Double

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

    public var isPercussion: Bool { !notes.isEmpty && channels == [MIDIImport.drumChannel] }
}

public struct Song: Sendable, Hashable {
    public let clips: [Clip]
    public let ticksPerBeat: Int
    public let tempoBPM: Double
    public let beatsPerBar: Double
    public let tempoChanges: Int

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

public struct PlacedNote: Sendable, Hashable {
    public let step: Int
    public let pitch: Int
    public let velocity: Int
    public let gate: Int
    public let timeShift: Int

    /// The lane this hit plays, or `nil` on a melodic note: `117` holds a lane, `109` a pitch.
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

public struct Placement: Sendable, Hashable {
    public let notes: [PlacedNote]
    public let stepCount: Int

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

public struct TrackPlan: Sendable, Hashable {
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

public struct SongPlan: Sendable, Hashable {
    public let tracks: [TrackPlan]

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

    public var track: Int { plan.tracks.first?.track ?? 1 }
    public var pattern: Int { plan.tracks.first?.placements.first?.pattern ?? 1 }
    public var stepCount: Int { plan.tracks.first?.placements.first?.stepCount ?? 0 }
}

struct TrackRead {
    var notes: [RenderedNote]

    var dropped: Int
}

extension MIDIImport {
    static func trackNotes(_ track: MusicalMIDI1File.Track, timebase: MusicalMIDIFileTimebase)
        -> TrackRead
    {
        var tick = 0
        var dropped = 0
        var notes: [RenderedNote] = []
        // A second note-on for a sounding pitch retriggers it; leftovers close in insertion order.
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

        for held in openOrder {
            guard let open = openNotes[held] else { continue }
            notes.append(
                RenderedNote(
                    tick: open.onset, durationTicks: max(0, tick - open.onset),
                    pitch: held.second, velocity: open.velocity, channel: held.first))
        }

        return TrackRead(notes: notes, dropped: dropped)
    }

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
                        // The file stores the denominator as a power of two.
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

    static func tempoToBPM(_ tempo: Int) -> Double {
        60 * 1_000_000 / Double(tempo)
    }

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
            if !options.midiTracks.isEmpty && !options.midiTracks.contains(number) { continue }
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
            if !options.midiTracks.isEmpty && !options.midiTracks.contains(number) { continue }
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
            beatsPerBar: Double(signature.numerator) * 4 / Double(signature.denominator),
            tempoChanges: changes,
            controllersDropped: dropped)
    }
}

struct Snapped {
    let step: Int

    let residual: Double

    let note: RenderedNote
}

extension MIDIImport {
    static func anchor(_ clips: [Clip], _ ticksPerStep: Double) -> Double {
        let first = clips.flatMap(\.notes).map(\.tick).min() ?? 0
        return Double(Arithmetic.pyRound(Double(first) / ticksPerStep)) * ticksPerStep
    }

    /// Nearest-step rounding cannot do this: at 75% a delayed step collapses onto the next one.
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
            // The epsilon makes the lowest percent win a tie, keeping an unswung source straight.
            if cost < bestCost - 1e-9 {
                bestPercent = percent
                bestCost = cost
            }
        }

        if bestPercent == low { return low }

        let swung = offsets.filter {
            Arithmetic.floorMod(assignStep($0, ticksPerStep, bestPercent).step, 2) != 0
        }.count
        return swung >= minSwungNotes ? bestPercent : low
    }

    static func fitShift(_ residual: Double, _ ticksPerBeat: Int) -> (
        stored: Int, remainder: Double
    ) {
        let unit = Double(ticksPerBeat) / Double(Constants.timeShiftUnitsPerBeat)
        let (low, high) = Constants.timeShiftRange
        let wanted = residual / unit
        let units = max(low, min(high, Arithmetic.pyRound(wanted)))
        return (Constants.timeShiftCentre + units, residual - Double(units) * unit)
    }

    static func gateFor(_ note: RenderedNote, _ ticksPerStep: Double) -> (stored: Int, exact: Bool)
    {
        let length = Double(note.durationTicks) / ticksPerStep
        let stored = Constants.encodeGate(length)
        return (stored, Constants.gateTable[stored] == length)
    }

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
        let halfShiftUnit = Double(ticksPerBeat) / Double(Constants.timeShiftUnitsPerBeat) / 2

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
                if abs(fitted.remainder) > halfShiftUnit {
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

        var crowded: [Int: Int] = [:]
        for note in notes {
            crowded[note.step, default: 0] += 1
        }
        let over = crowded.filter { $0.value > Constants.maxNotesPerStep }.map(\.key)
        if !over.isEmpty {
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
        let moved = snapped.count(where: { $0.residual != 0 })
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

    /// Lengths are per track, never padded: the device loops each track's chain on its own.
    public static func planTrack(
        _ clip: Clip, track: Int, collector: Collector, options: ImportOptions? = nil,
        isDrum: Bool = false, drumMap: DrumMap? = nil, firstPattern: Int = 1,
        stepsPerBar: Int = 16, origin: Double
    ) throws -> TrackPlan {
        let options = try options ?? ImportOptions()
        let ticksPerStep = Double(clip.ticksPerBeat) / Double(options.stepsPerBeat)
        let site = Site(track: track, kind: isDrum ? "drum" : "seq")

        let swing = options.fitSwing ? fitSwing(clip, ticksPerStep, origin) : straight
        let snapped = snap(clip, ticksPerStep, origin, swing)

        let ends = snapped.map {
            Double($0.step) + Double($0.note.durationTicks) / ticksPerStep
        }
        let furthest = Arithmetic.pyRound(ends.max() ?? 1)
        let total = max(1, Arithmetic.ceilDiv(furthest, stepsPerBar) * stepsPerBar)

        let moved = snapped.count(where: { $0.residual != 0 })
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

    public static func fitDrumMap(_ clip: Clip) throws -> DrumMap {
        let low = clip.notes.lazy.map(\.pitch).min() ?? DrumMap.defaultChromaticLow
        return try DrumMap.chromatic(max(DrumMap.minNote, min(low, DrumMap.maxChromaticLow)))
    }

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

    static func assign(
        _ song: Song, _ options: ImportOptions, _ collector: Collector, _ firstTrack: Int = 1
    ) throws -> [(clip: Clip, track: Int, isDrum: Bool)] {
        var drum: Clip?
        var melodic: [Clip]
        if let named = options.drumTrack {
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

        let drumSource = drum?.sourceTracks.first
        var routed: [(clip: Clip, track: Int)] = []
        var claimed: Set<Int> = []
        for route in options.routes {
            let matching = song.clips.filter { $0.sourceTracks == [route.source] }
            if matching.isEmpty {
                throw KSPError.value(
                    "track \(route.source) of the source holds no notes; route counts every track "
                        + "of the file from 1, including ones that carry only tempo or a name")
            }
            if route.source == drumSource {
                if route.device != 1 {
                    throw KSPError.value(
                        "route \(route.source):\(route.device) sends the drum track to device "
                            + "track \(route.device); only device track 1 carries a drum set")
                }
                continue
            }
            if route.device == 1 && drum != nil {
                throw KSPError.value(
                    "route \(route.source):1 collides with the drum track; only device track 1 "
                        + "carries a drum set")
            }
            routed.append((merged(matching), route.device))
            claimed.insert(route.device)
            melodic = melodic.filter { $0.sourceTracks != [route.source] }
        }

        var assigned: [(clip: Clip, track: Int, isDrum: Bool)] = []
        if let drum {
            assigned.append((drum, 1, true))
        }
        assigned.append(contentsOf: routed.map { ($0.clip, $0.track, false) })

        let free = (firstTrack...max(firstTrack, Constants.trackItemIDs.count)).filter {
            $0 <= Constants.trackItemIDs.count && (drum == nil || $0 != 1) && !claimed.contains($0)
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
        return assigned.stableSorted { $0.track < $1.track }
    }

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
                    + "channel became a device track of its own, except where --drum-track or "
                    + "--route merged the track back into one part",
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

extension MIDIImport {
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

            // Only a split track needs a chain; one pattern plays without one.
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

    public static func saveable(_ raw: RawProject) -> [(key: String, value: JSONValue)] {
        var project = raw
        if project["version"] == nil {
            project["version"] = .string(Constants.projectVersion)
        }
        return LenientJSON.canonical(project)
    }

    public static func patternStepCount(_ raw: RawProject, track: Int, pattern: Int) throws -> Int {
        let item = try Keys.itemForTrack(track)
        guard let stored = try Keys.getInt(raw, item, Constants.pSeqStepCount, pattern) else {
            throw KSPError.value("track \(track) pattern \(pattern) declares no step count")
        }
        return stored + Constants.stepCountOffset
    }

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

    public static func trackIsMelodic(_ raw: RawProject, track: Int) throws -> Bool {
        let item = try Keys.itemForTrack(track)
        let bits = try Keys.getInt(raw, item, Constants.pTrackModeBits) ?? 0
        return bits & (1 << Constants.drumModeBit) == 0
    }

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
