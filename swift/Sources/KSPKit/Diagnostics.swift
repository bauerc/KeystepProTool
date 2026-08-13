/// Structured diagnostics, and how they collapse for display. A port of `src/ksp/diagnostics.py`.
///
/// The format has more unknowns than a converter can hide, so this package says what it assumed
/// rather than deciding quietly. The problem is volume: one misread encoding affects dozens of
/// notes across a dozen patterns, and as free text that buries the one-off findings that matter.
///
/// So a diagnostic is a record, not a sentence. It carries a stable ``Code``, the ``Site`` it came
/// from, and how many notes or steps it is about. Reporting can then collapse a code's instances
/// into a single counted line, and expand them again on request, without pattern-matching on
/// English. Adding one means a ``Code`` member, a ``Diagnostics/summaries`` entry, and the call
/// site: there is no type per diagnostic, because the variation is data.
public enum Severity: String, Sendable, Hashable, Codable, CaseIterable {
    case warning
    case error
}

/// What kind of problem this is. Grouping keys off these, not off text.
public enum Code: String, Sendable, Hashable, Codable, CaseIterable {
    // --- reader ---
    case noVersionKey = "no-version-key"
    case mixedNoteSets = "mixed-note-sets"
    case drumModeFlagDisagrees = "drum-mode-flag-disagrees"
    case hasDataFlagDisagrees = "has-data-flag-disagrees"
    case trailingPoolValues = "trailing-pool-values"
    case drumLaneOutOfRange = "drum-lane-out-of-range"
    case flagWithoutNote = "flag-without-note"
    case disabledStepOff = "disabled-step-off"
    case patternBitsUnknown = "pattern-bits-unknown"
    case scaleOffList = "scale-off-list"
    case chainHasHole = "chain-has-hole"

    // --- drum map ---
    case drumMapAssumed = "drum-map-assumed"
    case drumMapDuplicate = "drum-map-duplicate"

    // --- export ---
    case disabledNotExported = "disabled-not-exported"
    case disabledExported = "disabled-exported"
    case staleNoteSet = "stale-note-set"
    case swingUnverified = "swing-unverified"
    case globalSwingNotApplied = "global-swing-not-applied"
    case disabledPastLastStep = "disabled-past-last-step"
    case gateShortened = "gate-shortened"
    case gateOffLadder = "gate-off-ladder"
    case timeShiftClipped = "time-shift-clipped"
    case stepSkipSinglePass = "step-skip-single-pass"
    case stepSkipExpanded = "step-skip-expanded"
    case directionNotApplied = "direction-not-applied"
    case drumLaneDropped = "drum-lane-dropped"
    case trackLengthsDiffer = "track-lengths-differ"
    case overlapsResolved = "overlaps-resolved"

    // --- import ---
    case clipAnchored = "clip-anchored"
    case notesQuantised = "notes-quantised"
    case pastPatternEnd = "past-pattern-end"
    case multipleSources = "multiple-sources"
    case patternSplit = "pattern-split"
    case poolOverflow = "pool-overflow"
    case tracksDropped = "tracks-dropped"
    case gateApproximated = "gate-approximated"
    case gatePastEnd = "gate-past-end"
    case tempoCarried = "tempo-carried"
    case tempoChangesIgnored = "tempo-changes-ignored"
    case swingFitted = "swing-fitted"
    case timingResidual = "timing-residual"
    case drumMapFitted = "drum-map-fitted"
    case drumPitchUnmapped = "drum-pitch-unmapped"
    case trackSplitByChannel = "track-split-by-channel"
    case controllersDropped = "controllers-dropped"
    case tempoOutOfRange = "tempo-out-of-range"
}

/// How one code's instances read once collapsed.
///
/// `template` is formatted with `{sites}` and `{subjects}`, each already a counted noun phrase --
/// "3 patterns", "41 notes". A template using neither is fine: some diagnostics are said once
/// however often they arise.
public struct Summary: Sendable, Hashable {
    public let template: String
    public let subject: String
    public let site: String

    public init(_ template: String, subject: String = "note", site: String = "pattern") {
        self.template = template
        self.subject = subject
        self.site = site
    }

    /// The template with both counts filled in.
    func rendered(sites: Int, subjects: Int) -> String {
        template
            .replacing("{sites}", with: counted(sites, site))
            .replacing("{subjects}", with: counted(subjects, subject))
    }
}

/// Where a diagnostic came from. Every part is optional.
public struct Site: Sendable, Hashable {
    public let track: Int?
    public let pattern: Int?
    public let kind: String?
    public let slot: Int?
    public let scene: Int?

    public init(
        track: Int? = nil, pattern: Int? = nil, kind: String? = nil, slot: Int? = nil,
        scene: Int? = nil
    ) {
        self.track = track
        self.pattern = pattern
        self.kind = kind
        self.slot = slot
        self.scene = scene
    }

    public func describe() -> String {
        var parts: [String] = []
        if let scene { parts.append("scene \(scene)") }
        if let track { parts.append("track \(track)") }
        if let pattern { parts.append("pattern \(pattern)") }
        if let slot { parts.append("slot \(slot)") }

        let text = parts.joined(separator: " ")
        guard let kind else { return text }
        return text.isEmpty ? "(\(kind))" : "\(text) (\(kind))"
    }
}

extension Site: Encodable {
    /// No `scene`, matching `Site.to_dict`. The JSON output is one of the two ports' shared
    /// contracts, so this stays as it is until both sides change together.
    enum CodingKeys: String, CodingKey {
        case track, pattern, kind, slot
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(track, forKey: .track)
        try container.encode(pattern, forKey: .pattern)
        try container.encode(kind, forKey: .kind)
        try container.encode(slot, forKey: .slot)
    }
}

/// One occurrence of one problem.
public struct Diagnostic: Sendable, Hashable, Encodable {
    public let code: Code

    /// The specific, full sentence -- what `--verbose` shows. No site prefix and no "warning:"
    /// prefix; both are added when rendering.
    public let detail: String

    public let site: Site
    public let severity: Severity

    /// How many notes, steps or lanes this one occurrence covers. Summed when the code is
    /// collapsed, which is why a single line can honestly say "41 notes across 3 patterns".
    public let subjects: Int

    public init(
        code: Code, detail: String, site: Site = Site(), severity: Severity = .warning,
        subjects: Int = 1
    ) {
        self.code = code
        self.detail = detail
        self.site = site
        self.severity = severity
        self.subjects = subjects
    }

    public var message: String {
        let location = site.describe()
        return location.isEmpty ? detail : "\(location): \(detail)"
    }

    /// Copy with the given site parts filled in, leaving the rest alone.
    ///
    /// For diagnostics crossing a boundary that knows more than the code that raised them: the
    /// reader knows the pattern, the export the track.
    public func at(
        track: Int? = nil, pattern: Int? = nil, kind: String? = nil, slot: Int? = nil
    ) -> Diagnostic {
        Diagnostic(
            code: code, detail: detail,
            site: Site(
                track: track ?? site.track, pattern: pattern ?? site.pattern,
                kind: kind ?? site.kind, slot: slot ?? site.slot, scene: site.scene),
            severity: severity, subjects: subjects)
    }
}

/// Every occurrence of one code, and what they add up to.
public struct Group: Sendable, Hashable {
    public let code: Code
    public let severity: Severity
    public let entries: [Diagnostic]

    public var sites: Int {
        Set(entries.map(\.site)).count
    }

    public var subjects: Int {
        entries.reduce(0) { $0 + $1.subjects }
    }

    /// The collapsed line.
    public var headline: String {
        // A group of one keeps its own message: there is nothing to collapse, so summarising
        // would lose its site for no gain.
        guard entries.count > 1, let summary = Diagnostics.summaries[code] else {
            return entries.first?.message ?? ""
        }
        return summary.rendered(sites: sites, subjects: subjects)
    }
}

/// An immutable set of diagnostics, in the order they were raised.
public struct Report: Sendable, Hashable {
    public let entries: [Diagnostic]

    public init(_ entries: [Diagnostic] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// Every diagnostic in full, as plain strings.
    public var messages: [String] { entries.map(\.message) }

    /// One group per code, in the order each code first appeared.
    public func grouped() -> [Group] {
        var order: [Code] = []
        var byCode: [Code: [Diagnostic]] = [:]
        for entry in entries {
            if byCode[entry.code] == nil {
                order.append(entry.code)
                byCode[entry.code] = []
            }
            byCode[entry.code]?.append(entry)
        }
        return order.compactMap { code in
            guard let entries = byCode[code], let first = entries.first else { return nil }
            return Group(code: code, severity: first.severity, entries: entries)
        }
    }

    public func render(verbose: Bool = false) -> [String] {
        verbose ? messages : grouped().map(\.headline)
    }

    /// The "there is more to see" line, or `nil` when there is not.
    public func note(verbose: Bool = false) -> String? {
        guard !verbose else { return nil }
        let kinds = grouped().count
        guard entries.count > kinds else { return nil }
        return "\(counted(entries.count, "warning")) collapsed into \(counted(kinds, "kind")); "
            + "--verbose for detail"
    }

    /// Concatenate, dropping anything the result already says.
    public func merge(_ other: Report) -> Report {
        let collector = Collector()
        collector.extend(entries)
        collector.extend(other.entries)
        return collector.report()
    }
}

extension Report: Sequence {
    public func makeIterator() -> IndexingIterator<[Diagnostic]> {
        entries.makeIterator()
    }
}

/// Builds a ``Report``, dropping exact repeats.
///
/// A class, not a struct: the reader and the export pass one collector down through the functions
/// that raise into it, which is the Python object's behaviour and not a value type's.
public final class Collector {
    // Deduplication keys on (code, site, detail) rather than the rendered string, so two
    // diagnostics that read alike but come from different patterns both survive and the counts
    // stay honest.
    private struct Fingerprint: Hashable {
        let code: Code
        let site: Site
        let detail: String
    }

    private var entries: [Diagnostic] = []
    private var seen: Set<Fingerprint> = []

    public init() {}

    public func add(
        _ code: Code, _ detail: String, site: Site = Site(), severity: Severity = .warning,
        subjects: Int = 1
    ) {
        push(
            Diagnostic(
                code: code, detail: detail, site: site, severity: severity, subjects: subjects))
    }

    public func push(_ diagnostic: Diagnostic) {
        let fingerprint = Fingerprint(
            code: diagnostic.code, site: diagnostic.site, detail: diagnostic.detail)
        guard seen.insert(fingerprint).inserted else { return }
        entries.append(diagnostic)
    }

    public func extend(_ diagnostics: some Sequence<Diagnostic>) {
        for diagnostic in diagnostics {
            push(diagnostic)
        }
    }

    public func report() -> Report {
        Report(entries)
    }
}

/// The summary table, kept as data so that adding a diagnostic does not mean adding a branch --
/// and so that both ports carry the same wording.
public enum Diagnostics {
    /// One entry per ``Code``.
    public static let summaries: [Code: Summary] = [
        .noVersionKey: Summary(
            "no 'version' key (factory template rather than a saved project)"),
        .mixedNoteSets: Summary(
            """
            {sites} hold both melodic and drum notes; parameter 86 bit 6 decides which set plays \
            and the other is stale. Both are reported
            """),
        .drumModeFlagDisagrees: Summary(
            "{sites} disagree with parameter 86 bit 6 about which note set is live"),
        .hasDataFlagDisagrees: Summary(
            "{sites} hold notes but parameter 40 says they have no data"),
        .trailingPoolValues: Summary(
            "{subjects} in {sites} sit after the end of a melodic note list and were ignored",
            subject: "value"),
        .drumLaneOutOfRange: Summary(
            "{sites} hold drum lanes outside the device's 24"),
        .patternBitsUnknown: Summary(
            "{sites} set a bit of parameter 99 / 116 that no capture accounted for (spec 3.3)"),
        .scaleOffList: Summary(
            "{sites} hold a scale index the device's list does not reach"),
        .chainHasHole: Summary(
            "{sites} hold a pattern chain with a gap in it; everything after the gap was ignored",
            site: "scene"),
        .flagWithoutNote: Summary(
            """
            {subjects} across {sites} are flagged active but hold no note. Every flagged step \
            should have a pooled note, so this means the note pool was decoded wrongly rather \
            than that the file is damaged
            """, subject: "step"),
        .disabledStepOff: Summary(
            """
            {sites} hold disabled notes ({subjects}, step turned off); they do not play on the \
            device
            """),
        .drumMapAssumed: Summary(
            """
            drum lanes were resolved through an assumed map; the KeyStep Pro drum map is a device \
            global and is not stored in the project file (spec 3.2.1)
            """),
        .drumMapDuplicate: Summary(
            "{subjects} are mapped from more than one drum lane; reverse lookup will use the "
                + "lowest"),
        .disabledNotExported: Summary(
            """
            {subjects} across {sites} are disabled (step turned off) and were not exported; \
            --include-disabled exports them
            """),
        .staleNoteSet: Summary(
            """
            {sites} hold notes in both parameter sets; only the set parameter 86 bit 6 calls live \
            was exported (--include-stale exports both)
            """),
        .swingUnverified: Summary(
            """
            {sites} carry swing; which steps move is measured (the even ones) but how far is not, \
            so the standard shuffle formula was used
            """),
        .globalSwingNotApplied: Summary(
            """
            the project sets a global swing (parameter 74); the per-pattern value takes precedence \
            on the device, so only the per-pattern value was applied
            """),
        .disabledPastLastStep: Summary(
            """
            {subjects} across {sites} are disabled (past the last step) and were not exported; \
            --include-disabled exports them
            """),
        .disabledExported: Summary(
            """
            {subjects} across {sites} are disabled but were exported because --include-disabled \
            is set; the device does not play them
            """),
        .gateShortened: Summary(
            """
            {sites} hold notes whose gate ran past the end of the pattern; they were shortened to \
            it
            """),
        .gateOffLadder: Summary(
            """
            {subjects} are off the 0-127 gate ladder and cannot be decoded; exported at the \
            default length
            """, subject: "encoding"),
        .timeShiftClipped: Summary(
            "{subjects} are shifted to before the start of the export and were held at it",
            subject: "note"),
        .stepSkipSinglePass: Summary(
            """
            notes are set to play on only some of the 16/32/48/64 sequences, which the device \
            plays as four repeats; --passes 1 renders one and includes them all
            """),
        .stepSkipExpanded: Summary(
            """
            {sites} were rendered as repeats so each note lands on the 16/32/48/64 sequences its \
            mask selects
            """),
        .directionNotApplied: Summary(
            """
            {sites} play in a non-forward direction, which no MIDI file can express; the export \
            renders them forward
            """),
        .drumLaneDropped: Summary(
            "{subjects} lie outside the device's 24 drum lanes and were dropped", subject: "lane"),
        .trackLengthsDiffer: Summary(
            """
            tracks hold different total lengths; this export aligns pattern N across tracks, but \
            the device loops each track on its own, so they drift apart
            """),
        .overlapsResolved: Summary(
            """
            {sites} hold overlapping notes of the same pitch; they were shortened so each has its \
            own note-off
            """),
        .clipAnchored: Summary(
            """
            the clip does not start at the beginning of the file; its first note was placed on \
            step 1 and the rest moved with it. A pattern is a loop, so it has nowhere to keep the \
            lead-in
            """),
        .notesQuantised: Summary(
            "{subjects} did not land on a step and were moved to the nearest one"),
        .pastPatternEnd: Summary(
            """
            {subjects} fall past the pattern's last step and were dropped; the device disables \
            notes beyond it, so writing them would put silent notes in the file
            """),
        .multipleSources: Summary(
            """
            notes were taken from more than one source track or channel and merged into one \
            pattern; --midi-track picks just one
            """),
        .patternSplit: Summary(
            """
            {sites} run longer than the device's 64-step maximum and were split across consecutive \
            patterns, chained in the current scene so they play as one sequence
            """, site: "track"),
        .poolOverflow: Summary(
            "{subjects} did not fit; a pattern holds 192 events and the firmware refuses the rest"),
        .tracksDropped: Summary(
            "{subjects} had nowhere to go; the device has four tracks", subject: "source track"),
        .gateApproximated: Summary(
            """
            {subjects} have a length the gate ladder cannot express exactly and took the nearest \
            rung; the ladder is coarse above 3 steps
            """),
        .gatePastEnd: Summary(
            """
            {subjects} are held past the pattern's last step; the device wraps the loop rather \
            than sustaining them
            """),
        .tempoCarried: Summary("the project tempo was set from the source file"),
        .tempoChangesIgnored: Summary(
            """
            the source changes tempo partway through; the device stores one tempo per project, so \
            only the first was taken
            """),
        .swingFitted: Summary(
            "{sites} carry a groove that was fitted to the device's per-pattern swing",
            site: "pattern"),
        .timingResidual: Summary(
            """
            {subjects} sit further off the grid than swing and time shift together can express, \
            and were left at the nearest representable position
            """),
        .drumMapFitted: Summary(
            """
            no drum map was given, so one was fitted to the source pitches. The real map lives in \
            device settings and is not in the project file
            """),
        .drumPitchUnmapped: Summary(
            "{subjects} fall outside the 24 lanes the drum map covers and were dropped"),
        .trackSplitByChannel: Summary(
            """
            {subjects} shared one source track and each became a device track of its own; a type 0 \
            file tells its instruments apart by channel and nothing else
            """, subject: "channel"),
        .controllersDropped: Summary(
            "{subjects} are not notes and were dropped; the device's patterns store notes only",
            subject: "event"),
        .tempoOutOfRange: Summary(
            """
            the source's tempo is outside the 30-240 BPM the device runs at, and was held to the \
            nearest end of it
            """),
    ]
}

/// Render a count with its noun: 3 -> "3 notes", 1 -> "1 note".
private func counted(_ count: Int, _ noun: String) -> String {
    count == 1 ? "\(count) \(noun)" : "\(count) \(noun)s"
}
