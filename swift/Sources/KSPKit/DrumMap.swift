/// Mapping the KeyStep Pro's 24 drum lanes to MIDI note numbers. A port of `src/ksp/drum_map.py`.
///
/// A drum note stores a **lane index** in parameter 117, not a pitch, and which note a lane
/// transmits is a global device setting absent from the project file (spec section 3.2.1). This
/// type therefore holds an *assumption about the user's device*, never a decoded fact, and every
/// consumer is expected to say which map it used -- see ``describe()``.
///
/// The 24 lanes and the chromatic-from-36 default both come from that section, where the parameter
/// table and capture D5 are recorded.
public struct DrumMap: Sendable, Hashable {
    /// What the device's Drum Map menu actually reads (D5). The manual and MCC's Custom defaults
    /// of 36..59 agree.
    public static let defaultChromaticLow = 36

    /// `globalParamId 79` (Drum output) defaults to 10, separately from tracks 1-4 which default
    /// to 0-3.
    public static let defaultDrumChannel = 10

    /// Highest Low note the device's encoder reaches in chromatic mode (D5), the same cap MCC
    /// applies.
    public static let maxChromaticLow = 103

    public static let minNote = 0
    public static let maxNote = 127

    public let notes: [Int]
    public let name: String

    /// Non-fatal oddities, e.g. a custom map that sends two lanes to the same note. Reported,
    /// never silently repaired.
    public let diagnostics: Report

    public var warnings: [String] { diagnostics.messages }

    /// Validating initialiser; prefer ``chromatic(_:)`` or ``custom(_:)``, which also name the map.
    public init(notes: [Int], name: String = "chromatic-36", diagnostics: Report = Report()) throws
    {
        guard notes.count == Constants.drumLaneCount else {
            throw KSPError.value(
                "a drum map needs exactly \(Constants.drumLaneCount) notes, got \(notes.count)")
        }
        for (lane, note) in notes.enumerated() where !(Self.minNote...Self.maxNote ~= note) {
            throw KSPError.value(
                "lane \(lane) maps to note \(note), outside \(Self.minNote)-\(Self.maxNote)")
        }

        self.notes = notes
        self.name = name

        var counts: [Int: Int] = [:]
        for note in notes { counts[note, default: 0] += 1 }
        let duplicates = counts.filter { $0.value > 1 }.keys.sorted()
        guard !duplicates.isEmpty, diagnostics.isEmpty else {
            self.diagnostics = diagnostics
            return
        }
        // The hardware permits this, so it is not an error -- but it makes note -> lane lossy, and
        // a converter silently picking one lane is exactly the kind of quiet wrong answer this
        // project avoids.
        let collector = Collector()
        for note in duplicates {
            let lanes = notes.indices.filter { notes[$0] == note }
            collector.add(
                .drumMapDuplicate,
                "note \(note) is mapped from lanes \(lanes); reverse lookup will use the lowest")
        }
        self.diagnostics = collector.report()
    }

    /// Lane *i* plays `low + i`, the device's Chromatic mode.
    public static func chromatic(_ low: Int = defaultChromaticLow) throws -> DrumMap {
        // The device stops at Low note 103 too, which leaves the top lane on 126 -- Arturia's
        // range is one short of 127 rather than this being an off-by-one, since D5 saw lane 0 fire
        // 36 at a low note of 36. No separate overflow check is needed: 103 + 23 cannot exceed 127.
        guard minNote...maxChromaticLow ~= low else {
            throw KSPError.value(
                "chromatic low note \(low) is outside \(minNote)-\(maxChromaticLow)")
        }
        return try DrumMap(
            notes: Array(low..<(low + Constants.drumLaneCount)), name: "chromatic-\(low)")
    }

    /// An explicit 24-entry map, the device's Custom Notes mode.
    public static func custom(_ notes: [Int]) throws -> DrumMap {
        try DrumMap(notes: notes, name: "custom")
    }

    /// Build from an already-decoded config file.
    ///
    /// Deliberately takes parsed data, not a path: this module must not decide where files live.
    /// The CLI reads the file and passes the result in, as `DrumMap.from_dict` has it do.
    public static func from(_ config: DrumMapConfig) throws -> DrumMap {
        switch config.mode ?? "chromatic" {
        case "chromatic":
            return try chromatic(config.low ?? defaultChromaticLow)
        case "custom":
            guard let notes = config.notes else {
                throw KSPError.value("'notes' must be a list of integers")
            }
            return try custom(notes)
        case let mode:
            throw KSPError.value(
                "unknown drum map mode '\(mode)', expected 'chromatic' or 'custom'")
        }
    }

    /// Whether `lane` is one the device actually has.
    public func hasLane(_ lane: Int) -> Bool {
        0..<Constants.drumLaneCount ~= lane
    }

    /// The MIDI note lane `lane` transmits.
    public func noteForLane(_ lane: Int) throws -> Int {
        guard hasLane(lane) else {
            throw KSPError.value("lane \(lane) is outside 0-\(Constants.drumLaneCount - 1)")
        }
        return notes[lane]
    }

    /// The lane that plays `note`, or `nil` if the map does not reach it.
    ///
    /// `nil` is a real answer and must not be smoothed over. Snapping an unmapped drum hit to the
    /// nearest lane produces a file that loads cleanly and plays the wrong instrument, with
    /// nothing to signal the error -- the same failure mode as a guessed gate table.
    public func laneForNote(_ note: Int) -> Int? {
        notes.firstIndex(of: note)
    }

    /// One line naming the map and flagging that it is an assumption.
    public func describe() -> String {
        let what = name.hasPrefix("chromatic-") ? "chromatic from \(notes[0])" : "custom"
        return "\(what) (assumed - not in file)"
    }

    /// Render a lane as `lane 0 -> C1 (36) Bass Drum 1`.
    ///
    /// A lane the device does not have is shown as-is rather than resolved. The reader warns about
    /// those separately; inventing a note for one here would hide it.
    public func labelForLane(_ lane: Int) -> String {
        guard hasLane(lane) else { return "lane \(lane) (out of range)" }
        let note = notes[lane]
        let rendered = "lane \(lane) -> \(Constants.noteName(note)) (\(note))"
        guard let name = Self.gmDrumNames[note] else { return rendered }
        return "\(rendered) \(name)"
    }

    public func toJSON() -> JSONNode {
        .object([
            ("name", .string(name)),
            ("notes", .array(notes.map { .int($0) })),
            ("warnings", .array(warnings.map { .string($0) })),
        ])
    }

    /// General MIDI percussion names, keyed by **MIDI note rather than by lane**, so they stay
    /// correct under any drum map -- including a custom one where lane order says nothing about
    /// which instrument is where.
    public static let gmDrumNames: [Int: String] = [
        35: "Acoustic Bass Drum",
        36: "Bass Drum 1",
        37: "Side Stick",
        38: "Acoustic Snare",
        39: "Hand Clap",
        40: "Electric Snare",
        41: "Low Floor Tom",
        42: "Closed Hi-Hat",
        43: "High Floor Tom",
        44: "Pedal Hi-Hat",
        45: "Low Tom",
        46: "Open Hi-Hat",
        47: "Low-Mid Tom",
        48: "Hi-Mid Tom",
        49: "Crash Cymbal 1",
        50: "High Tom",
        51: "Ride Cymbal 1",
        52: "Chinese Cymbal",
        53: "Ride Bell",
        54: "Tambourine",
        55: "Splash Cymbal",
        56: "Cowbell",
        57: "Crash Cymbal 2",
        58: "Vibraslap",
        59: "Ride Cymbal 2",
        60: "Hi Bongo",
        61: "Low Bongo",
        62: "Mute Hi Conga",
        63: "Open Hi Conga",
        64: "Low Conga",
        65: "High Timbale",
        66: "Low Timbale",
        67: "High Agogo",
        68: "Low Agogo",
        69: "Cabasa",
        70: "Maracas",
        71: "Short Whistle",
        72: "Long Whistle",
        73: "Short Guiro",
        74: "Long Guiro",
        75: "Claves",
        76: "Hi Wood Block",
        77: "Low Wood Block",
        78: "Mute Cuica",
        79: "Open Cuica",
        80: "Mute Triangle",
        81: "Open Triangle",
    ]
}

/// A user's own drum map, as their config file spells it.
///
/// `mode` chooses between the device's two: `chromatic` takes `low`, `custom` takes all 24
/// `notes`. Both fields are optional here because the Python reads them out of a plain dict with
/// defaults; ``DrumMap/from(_:)`` applies the same ones.
public struct DrumMapConfig: Decodable, Sendable, Hashable {
    public let mode: String?
    public let low: Int?
    public let notes: [Int]?

    public init(mode: String? = nil, low: Int? = nil, notes: [Int]? = nil) {
        self.mode = mode
        self.low = low
        self.notes = notes
    }
}
