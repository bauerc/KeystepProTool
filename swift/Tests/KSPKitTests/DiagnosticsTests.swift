import Foundation
import Testing

@testable import KSPKit

private let describedSites = [
    (Site(), ""),
    (Site(track: 1), "track 1"),
    (Site(pattern: 9), "pattern 9"),
    (Site(pattern: 9, kind: "drum"), "pattern 9 (drum)"),
    (Site(track: 1, pattern: 9, kind: "drum"), "track 1 pattern 9 (drum)"),
    (Site(pattern: 9, slot: 1), "pattern 9 slot 1"),
    (Site(kind: "drum"), "(drum)"),
    (Site(track: 2, scene: 1), "scene 1 track 2"),
]

/// Twin of `tests/test_diagnostics.py`.
///
/// The point of the module is that one problem affecting forty notes reads as one line by default
/// and forty lines on request, without either view inventing or losing anything.
@Suite struct DiagnosticsTests {
    /// Two occurrences of one code at different sites, and one of another.
    let report: Report

    init() {
        let collector = Collector()
        collector.add(
            .disabledStepOff, "5 disabled note(s), step turned off",
            site: Site(track: 1, pattern: 5, kind: "drum"), subjects: 5)
        collector.add(
            .disabledStepOff, "2 disabled note(s), step turned off",
            site: Site(track: 1, pattern: 9, kind: "drum"), subjects: 2)
        collector.add(.timeShiftClipped, "notes carry a non-zero time shift")
        report = collector.report()
    }

    // MARK: - Sites and messages

    @Test(arguments: describedSites)
    func siteDescribesItself(site: Site, expected: String) {
        #expect(site.describe() == expected)
    }

    @Test func messagePrefixesTheSite() {
        let entry = Diagnostic(
            code: .gateShortened, detail: "a gate was shortened", site: Site(track: 1, pattern: 2))
        #expect(entry.message == "track 1 pattern 2: a gate was shortened")
    }

    @Test func messageOmitsAnEmptySite() {
        #expect(
            Diagnostic(code: .timeShiftClipped, detail: "shift not applied").message
                == "shift not applied")
    }

    @Test func atFillsInSitePartsWithoutLosingTheRest() {
        // The export knows the track; the reader that raised this did not.
        let entry = Diagnostic(
            code: .flagWithoutNote, detail: "detail", site: Site(pattern: 9, kind: "drum"))
        #expect(entry.at(track: 3).site == Site(track: 3, pattern: 9, kind: "drum"))
    }

    // MARK: - Collection

    @Test func exactRepeatsAreDropped() {
        let collector = Collector()
        for _ in 0..<3 {
            collector.add(.timeShiftClipped, "shift not applied")
        }
        #expect(collector.report().count == 1)
    }

    @Test func theSameCodeAtDifferentSitesSurvives() {
        // Otherwise the counts would under-report, which is worse than noise.
        let collector = Collector()
        collector.add(.disabledStepOff, "2 notes", site: Site(pattern: 1), subjects: 2)
        collector.add(.disabledStepOff, "2 notes", site: Site(pattern: 5), subjects: 2)
        #expect(collector.report().count == 2)
    }

    @Test func insertionOrderIsKept() {
        let collector = Collector()
        collector.add(.gateShortened, "first")
        collector.add(.timeShiftClipped, "second")
        #expect(collector.report().messages == ["first", "second"])
    }

    // MARK: - Grouping and rendering

    @Test func groupingIsByCodeInFirstAppearanceOrder() {
        #expect(report.grouped().map(\.code) == [.disabledStepOff, .timeShiftClipped])
    }

    @Test func aGroupCountsSitesAndSubjects() {
        let group = report.grouped()[0]
        #expect(group.sites == 2)
        #expect(group.subjects == 7)
    }

    @Test func theDefaultViewIsOneLinePerCode() {
        let lines = report.render()
        #expect(lines.count == 2)
        #expect(
            lines[0] == "2 patterns hold disabled notes (7 notes, step turned off); "
                + "they do not play on the device")
    }

    @Test func aGroupOfOneKeepsItsOwnMessage() {
        // Collapsing a single occurrence would lose its site for no gain.
        #expect(report.render()[1] == "notes carry a non-zero time shift")
    }

    @Test func verboseIsEveryOccurrence() {
        #expect(report.render(verbose: true) == report.messages)
        #expect(report.render(verbose: true).count == 3)
    }

    @Test func verboseIsASupersetOfTheDefault() {
        // The default must never say something verbose does not support.
        #expect(report.render(verbose: true).count >= report.render().count)
    }

    @Test func theNoteSaysHowMuchWasHidden() {
        #expect(report.note() == "3 warnings collapsed into 2 kinds; --verbose for detail")
    }

    @Test func noNoteWhenNothingCollapsed() {
        let collector = Collector()
        collector.add(.gateShortened, "one")
        collector.add(.timeShiftClipped, "two")
        #expect(collector.report().note() == nil)
    }

    @Test func noNoteWhenVerbose() {
        #expect(report.note(verbose: true) == nil)
    }

    @Test func anEmptyReportRendersToNothing() {
        let empty = Report()
        #expect(empty.isEmpty)
        #expect(empty.render().isEmpty)
        #expect(empty.note() == nil)
    }

    @Test func mergeConcatenatesAndDeduplicates() {
        // Exporting several files must not repeat a caveat once per file.
        let first = Collector()
        first.add(.drumMapAssumed, "chromatic from 36")
        let second = Collector()
        second.add(.drumMapAssumed, "chromatic from 36")
        second.add(.gateShortened, "shortened", site: Site(pattern: 2))
        #expect(first.report().merge(second.report()).count == 2)
    }

    // MARK: - The table

    @Test func everyCodeHasASummary() {
        // A missing entry would leave a code with nothing to collapse into.
        #expect(Set(Diagnostics.summaries.keys) == Set(Code.allCases))
    }

    /// Catches a template naming a placeholder the formatter does not supply.
    @Test(arguments: Code.allCases)
    func everySummaryRenders(code: Code) {
        let collector = Collector()
        for pattern in [1, 2] {
            collector.add(code, "detail", site: Site(pattern: pattern), subjects: 3)
        }
        let headline = collector.report().grouped()[0].headline
        #expect(!headline.isEmpty)
        #expect(!headline.contains("{"))
    }

    @Test func countedNounsAreSingularAtOne() {
        let collector = Collector()
        collector.add(.flagWithoutNote, "a", site: Site(pattern: 1), subjects: 1)
        collector.add(.flagWithoutNote, "b", site: Site(pattern: 1, slot: 2), subjects: 1)
        #expect(collector.report().grouped()[0].headline.hasPrefix("2 steps across 2 patterns"))
    }

    @Test func severityDefaultsToWarning() {
        #expect(Diagnostic(code: .gateShortened, detail: "x").severity == .warning)
    }

    @Test func encodesToTheSameShapeAsThePythonDict() throws {
        let entry = Diagnostic(
            code: .disabledStepOff, detail: "detail",
            site: Site(track: 1, pattern: 9, kind: "drum"), subjects: 2)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(entry), as: UTF8.self)

        // The site carries no scene, as `Site.to_dict` does not either.
        #expect(
            json == """
                {"code":"disabled-step-off","detail":"detail","severity":"warning",\
                "site":{"kind":"drum","pattern":9,"slot":null,"track":1},"subjects":2}
                """)
    }
}
