import Foundation
import KSPKit
import KSPRun
import Testing

@testable import KSPApp

private typealias Pattern = (pattern: Int, steps: Int, notes: Int, perStep: Int, dropped: Int)

private func segmented(
    _ deviceTrack: Int, source: Int? = nil, patterns: [Pattern] = [], droppedPatterns: Int = 0
) -> SegmentedTrack {
    var step = 1
    var segments: [Segment] = []
    for entry in patterns {
        segments.append(
            Segment(
                pattern: entry.pattern, stepCount: entry.steps, firstStep: step,
                noteCount: entry.notes, mostNotesOnAStep: entry.perStep,
                droppedNotes: entry.dropped))
        step += entry.steps
    }
    return SegmentedTrack(
        deviceTrack: deviceTrack, sourceTrack: source,
        noteCount: segments.reduce(0) { $0 + $1.noteCount }, segments: segments,
        droppedPatterns: droppedPatterns)
}

/// One filled track, one pattern, with every figure a long way from every wall.
private func modest(
    steps: Int = 16, notes: Int = 8, perStep: Int = 1, dropped: Int = 0, pattern: Int = 1
) -> SegmentationSummary {
    SegmentationSummary(
        tracks: [
            segmented(
                1, source: 1,
                patterns: [
                    (
                        pattern: pattern, steps: steps, notes: notes, perStep: perStep,
                        dropped: dropped
                    )
                ])
        ])
}

/// Four filled tracks, so the track count is at the wall without anything having been refused.
private func full(unplaced: [UnplacedSource] = []) -> SegmentationSummary {
    SegmentationSummary(
        tracks: (1...4).map {
            segmented(
                $0, source: $0,
                patterns: [(pattern: 1, steps: 16, notes: 4, perStep: 1, dropped: 0)])
        },
        unplaced: unplaced)
}

private func gauge(_ limits: Limits, _ name: String) throws -> Limits.Gauge {
    try #require(limits.gauges.first { $0.name == name }, "no \(name) gauge")
}

@Suite struct LimitsTests {
    @Test func alltheDevicesLimitsAreShownWhateverThePlanFilled() {
        let limits = Limits(modest())

        #expect(limits.gauges.count == 5)
        #expect(
            limits.gauges.map(\.name) == [
                "Tracks", "Patterns per track", "Steps per pattern", "Notes per pattern",
                "Notes per step",
            ])
        #expect(
            limits.gauges.map(\.limit) == [
                Constants.trackItemIDs.count, Constants.patternsPerTrack, Constants.maxSteps,
                Constants.poolCapacity, Constants.maxNotesPerStep,
            ])
    }

    @Test func anemptyPlanReadsAsZeroAgainstEveryLimit() {
        let limits = Limits(SegmentationSummary(tracks: []))

        #expect(limits.gauges.allSatisfy { $0.used == 0 })
        #expect(limits.gauges.allSatisfy { $0.status == .within })
        #expect(limits.exceeded.isEmpty)
    }

    @Test func atrackHoldingNoPatternIsNotATrackTheImportFilled() throws {
        let limits = Limits(
            SegmentationSummary(tracks: [segmented(1, source: 1), segmented(2, source: 2)]))

        #expect(try gauge(limits, "Tracks").used == 0)
    }

    // MARK: The three quarters rule

    @Test func afigureWellShortOfTheWallIsWithinIt() throws {
        let limits = Limits(modest(steps: 16, notes: 8, perStep: 2))

        #expect(try gauge(limits, "Steps per pattern").status == .within)
        #expect(try gauge(limits, "Notes per pattern").status == .within)
        #expect(try gauge(limits, "Notes per step").status == .within)
    }

    /// Exactly three quarters of the way, which is where amber begins on all five.
    @Test func threeQuartersOfTheWayIsAlreadyApproaching() throws {
        let limits = Limits(modest(steps: 48, notes: 144, perStep: 12, pattern: 12))

        #expect(try gauge(limits, "Patterns per track").status == .near)
        #expect(try gauge(limits, "Steps per pattern").status == .near)
        #expect(try gauge(limits, "Notes per pattern").status == .near)
        #expect(try gauge(limits, "Notes per step").status == .near)
    }

    @Test func threeOfTheFourTracksIsApproachingToo() throws {
        let limits = Limits(
            SegmentationSummary(
                tracks: (1...3).map {
                    segmented(
                        $0, source: $0,
                        patterns: [(pattern: 1, steps: 16, notes: 4, perStep: 1, dropped: 0)])
                }))

        #expect(try gauge(limits, "Tracks").used == 3)
        #expect(try gauge(limits, "Tracks").status == .near)
    }

    @Test func apatternFilledToTheBrimIsWithinRatherThanApproaching() throws {
        let limits = Limits(modest(steps: 64, notes: Constants.poolCapacity, perStep: 3))

        let notesPerPattern = try gauge(limits, "Notes per pattern")
        #expect(notesPerPattern.used == Constants.poolCapacity)
        #expect(notesPerPattern.status == .within)
        #expect(notesPerPattern.warnings.isEmpty)
    }

    /// 64 of 64 steps is the length the device runs a pattern at, not a wall being approached.
    @Test func afullTrackOfStepsIsWithinRatherThanApproaching() throws {
        let limits = Limits(modest(steps: Constants.maxSteps, notes: 32, perStep: 2))

        #expect(try gauge(limits, "Steps per pattern").used == Constants.maxSteps)
        #expect(try gauge(limits, "Steps per pattern").status == .within)
    }

    @Test func afullDeviceIsWithinRatherThanApproaching() throws {
        let limits = Limits(full())

        #expect(try gauge(limits, "Tracks").used == Constants.trackItemIDs.count)
        #expect(try gauge(limits, "Tracks").status == .within)
        #expect(limits.exceeded.isEmpty)
    }

    @Test func theStepBelowTheWallIsStillApproaching() throws {
        let limits = Limits(modest(steps: Constants.maxSteps - 1, notes: 32, perStep: 2))

        #expect(try gauge(limits, "Steps per pattern").status == .near)
    }

    // MARK: What the planner refused

    @Test func apatternPastThePoolIsExceededAndSaysWhereAndByHowMuch() throws {
        let limits = Limits(
            SegmentationSummary(
                tracks: [
                    segmented(
                        2, source: 4,
                        patterns: [
                            (pattern: 1, steps: 64, notes: 32, perStep: 1, dropped: 0),
                            (
                                pattern: 2, steps: 64, notes: Constants.poolCapacity, perStep: 4,
                                dropped: 40
                            ),
                        ])
                ]))

        let notesPerPattern = try gauge(limits, "Notes per pattern")
        #expect(notesPerPattern.status == .over)
        #expect(notesPerPattern.site == "Track 2, pattern 2")
        #expect(notesPerPattern.warnings.count == 1)
        #expect(notesPerPattern.warnings[0].contains("Track 2, pattern 2"))
        #expect(notesPerPattern.warnings[0].contains("40 notes"))
        #expect(notesPerPattern.warnings[0].contains("\(Constants.poolCapacity)"))
    }

    @Test func asourceThatWillNotFitExceedsTheTrackCountAndIsNamed() throws {
        let limits = Limits(
            full(unplaced: [
                UnplacedSource(sourceTrack: 5, noteCount: 12),
                UnplacedSource(sourceTrack: 6, noteCount: 3),
            ]))

        let tracks = try gauge(limits, "Tracks")
        #expect(tracks.used == Constants.trackItemIDs.count)
        #expect(tracks.status == .over)
        #expect(tracks.warnings.count == 2)
        #expect(tracks.warnings[0].contains("Source track 5"))
        #expect(tracks.warnings[0].contains("will not fit"))
        #expect(tracks.warnings[1].contains("Source track 6"))
    }

    @Test func asourceThatOnlyPartlyFitsSaysWhichPartDidNot() throws {
        let limits = Limits(
            full(unplaced: [
                UnplacedSource(sourceTrack: 3, droppedParts: 1, placedParts: 2, noteCount: 9)
            ]))

        let tracks = try gauge(limits, "Tracks")
        #expect(tracks.warnings.count == 1)
        #expect(tracks.warnings[0].contains("Source track 3"))
        #expect(tracks.warnings[0].contains("3 channels"))
        #expect(tracks.warnings[0].contains("1 channel would be dropped"))
        #expect(!tracks.warnings[0].contains("9"))
    }

    @Test func adroppedTailExceedsThePatternCountAndSaysHowMuchWent() throws {
        let limits = Limits(
            SegmentationSummary(
                tracks: [
                    segmented(
                        1, source: 3,
                        patterns: [(pattern: 16, steps: 64, notes: 8, perStep: 1, dropped: 0)],
                        droppedPatterns: 2)
                ]))

        let patterns = try gauge(limits, "Patterns per track")
        #expect(patterns.used == Constants.patternsPerTrack)
        #expect(patterns.status == .over)
        #expect(patterns.warnings.count == 1)
        #expect(patterns.warnings[0].contains("Track 1"))
        #expect(patterns.warnings[0].contains("2 patterns"))
        // The device's own count, not the grid's column count, which only happens to match.
        #expect(patterns.warnings[0].contains("pattern \(Constants.patternsPerTrack)"))
    }

    @Test func thepatternGaugeCountsHowFarTheRunReachesNotHowManyItHolds() throws {
        let limits = Limits(
            SegmentationSummary(
                tracks: [
                    segmented(
                        1, source: 1,
                        patterns: [
                            (pattern: 14, steps: 64, notes: 8, perStep: 1, dropped: 0),
                            (pattern: 15, steps: 64, notes: 8, perStep: 1, dropped: 0),
                        ])
                ]))

        let patterns = try gauge(limits, "Patterns per track")
        #expect(patterns.used == 15)
        #expect(patterns.status == .near)
    }

    // MARK: Where the figure was found

    @Test func eachGaugeNamesTheTrackAndPatternItsFigureCameFrom() throws {
        let limits = Limits(
            SegmentationSummary(
                tracks: [
                    segmented(
                        1, source: 1,
                        patterns: [(pattern: 1, steps: 16, notes: 4, perStep: 1, dropped: 0)]),
                    segmented(
                        3, source: 2,
                        patterns: [(pattern: 5, steps: 64, notes: 90, perStep: 6, dropped: 0)]),
                ]))

        #expect(try gauge(limits, "Steps per pattern").site == "Track 3, pattern 5")
        #expect(try gauge(limits, "Notes per pattern").site == "Track 3, pattern 5")
        #expect(try gauge(limits, "Notes per step").site == "Track 3, pattern 5")
        #expect(try gauge(limits, "Patterns per track").site == "Track 3")
    }

    @Test func thetrackGaugeNamesNoPlaceBecauseItIsTheWholePlan() throws {
        #expect(try gauge(Limits(modest()), "Tracks").site == nil)
    }

    @Test func asiteIsNamedOnlyOnTheFirstGaugeFoundThere() {
        let limits = Limits(
            SegmentationSummary(
                tracks: [
                    segmented(
                        1, source: 1,
                        patterns: [(pattern: 1, steps: 16, notes: 4, perStep: 1, dropped: 0)]),
                    segmented(
                        3, source: 2,
                        patterns: [(pattern: 5, steps: 64, notes: 90, perStep: 6, dropped: 0)]),
                ]))

        #expect(
            limits.gauges.map { limits.shownSite($0) }
                == [nil, "Track 3", "Track 3, pattern 5", nil, nil])
    }

    @Test func anemptyPlanNamesNoPlaceEither() {
        let limits = Limits(SegmentationSummary(tracks: []))

        #expect(limits.gauges.allSatisfy { $0.site == nil })
    }

    // MARK: What the view reads

    @Test func agaugeReadsAsItsFigureOverItsLimit() throws {
        #expect(try gauge(Limits(modest(steps: 48)), "Steps per pattern").figure == "48 / 64")
    }

    @Test func exceededCollectsOnlyTheLimitsThatWereActuallyPassed() {
        let limits = Limits(full(unplaced: [UnplacedSource(sourceTrack: 5, noteCount: 12)]))

        #expect(limits.exceeded.map(\.name) == ["Tracks"])
    }

    // MARK: The verdict the meters are read under

    @Test func aplanClearOfEveryWallFits() {
        let verdict = Limits(modest()).verdict

        #expect(verdict.status == .within)
        #expect(verdict.text == "Fits")
    }

    @Test func aplanNearAWallStillFitsAndCountsTheWallsItIsNear() {
        let verdict = Limits(modest(steps: 48, notes: 144, perStep: 12, pattern: 12)).verdict

        #expect(verdict.status == .near)
        #expect(verdict.text == "Fits, 4 limits close")
    }

    @Test func onenearWallIsCountedInTheSingular() {
        let verdict = Limits(modest(steps: 48)).verdict

        #expect(verdict.text == "Fits, 1 limit close")
    }

    @Test func adroppedTailReadsAsTheseManyPatternsOver() {
        let verdict =
            Limits(
                SegmentationSummary(
                    tracks: [
                        segmented(
                            1, source: 3,
                            patterns: [(pattern: 16, steps: 64, notes: 8, perStep: 1, dropped: 0)],
                            droppedPatterns: 3)
                    ])
            ).verdict

        #expect(verdict.status == .over)
        #expect(verdict.text == "3 patterns over")
    }

    @Test func overflowedNotesReadInNotes() {
        let verdict = Limits(modest(steps: 64, notes: Constants.poolCapacity, dropped: 40)).verdict

        #expect(verdict.text == "40 notes over")
    }

    @Test func unplacedSourcesReadInTracks() {
        let verdict =
            Limits(
                full(unplaced: [
                    UnplacedSource(sourceTrack: 5, noteCount: 12),
                    UnplacedSource(sourceTrack: 6, droppedParts: 2, placedParts: 1, noteCount: 3),
                ])
            ).verdict

        #expect(verdict.text == "3 tracks over")
    }

    @Test func severalWallsPassedAreNamedInTheOrderTheMetersRunIn() {
        let verdict =
            Limits(
                SegmentationSummary(
                    tracks: [
                        segmented(
                            1, source: 1,
                            patterns: [
                                (
                                    pattern: 16, steps: 64, notes: Constants.poolCapacity,
                                    perStep: 4, dropped: 40
                                )
                            ],
                            droppedPatterns: 3)
                    ],
                    unplaced: [UnplacedSource(sourceTrack: 5, noteCount: 12)])
            ).verdict

        #expect(verdict.text == "1 track, 3 patterns and 40 notes over")
    }

    @Test func twowallsPassedAreJoinedWithoutAComma() {
        let verdict =
            Limits(
                SegmentationSummary(
                    tracks: [
                        segmented(
                            1, source: 1,
                            patterns: [(pattern: 16, steps: 64, notes: 8, perStep: 1, dropped: 0)],
                            droppedPatterns: 3)
                    ],
                    unplaced: [UnplacedSource(sourceTrack: 5, noteCount: 12)])
            ).verdict

        #expect(verdict.text == "1 track and 3 patterns over")
    }

    @Test func awallPassedOutranksAWallMerelyApproached() {
        let verdict =
            Limits(
                SegmentationSummary(
                    tracks: [
                        segmented(
                            1, source: 1,
                            patterns: [(pattern: 16, steps: 48, notes: 8, perStep: 1, dropped: 0)],
                            droppedPatterns: 3)
                    ])
            ).verdict

        #expect(verdict.status == .over)
        #expect(verdict.text == "3 patterns over")
    }

    @Test func thewallsTheDeviceOnlyTruncatesToAreNeverCountedAsOver() {
        #expect(
            Limits(modest(steps: Constants.maxSteps, notes: 32, perStep: 16)).verdict.text
                == "Fits")
    }
}
