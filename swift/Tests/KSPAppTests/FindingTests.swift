import KSPKit
import KSPRun
import Testing

@testable import KSPApp

@Suite struct FindingTests {
    private var mixed: Report {
        Report([
            Diagnostic(code: .notesQuantised, detail: "first warning", site: Site(track: 1)),
            Diagnostic(
                code: .poolOverflow, detail: "first error", site: Site(track: 2),
                severity: .error),
            Diagnostic(code: .notesQuantised, detail: "second warning", site: Site(track: 3)),
            Diagnostic(
                code: .tracksDropped, detail: "second error", site: Site(track: 4),
                severity: .error),
        ])
    }

    @Test func arowIsARenderedLineAtEitherSetting() {
        for verbose in [false, true] {
            let rows = mixed.rows(verbose: verbose).map(\.text)

            #expect(rows.sorted() == mixed.render(verbose: verbose).sorted())
            #expect(rows.count == mixed.render(verbose: verbose).count)
        }
    }

    @Test func anerrorSortsAboveAWarning() {
        #expect(mixed.rows(verbose: true).map(\.severity) == [.error, .error, .warning, .warning])
        #expect(mixed.rows(verbose: false).map(\.severity) == [.error, .error, .warning])
    }

    /// `Array.sorted` promises no stability, and the report's own order inside a severity is
    /// meaningful: the sites are read in the order the planner walked them.
    @Test func aseverityKeepsTheReportsOwnOrderInsideIt() {
        let warnings = mixed.rows(verbose: true).filter { $0.severity == .warning }

        #expect(warnings.map(\.text) == ["track 1: first warning", "track 3: second warning"])
        #expect(
            mixed.rows(verbose: true).filter { $0.severity == .error }.map(\.text)
                == ["track 2: first error", "track 4: second error"])
    }

    @Test func acollapsedRowTakesTheGravestSeverityInItsGroup() {
        let report = Report([
            Diagnostic(code: .notesQuantised, detail: "one", site: Site(track: 1)),
            Diagnostic(
                code: .notesQuantised, detail: "two", site: Site(track: 2), severity: .error),
        ])

        #expect(report.rows(verbose: false).map(\.severity) == [.error])
        #expect(report.rows(verbose: true).map(\.severity) == [.error, .warning])
    }

    @Test func anemptyReportYieldsNoRows() {
        #expect(Report().rows(verbose: false).isEmpty)
        #expect(Report().rows(verbose: true).isEmpty)
    }

    @Test func anoutcomeDerivesItsStringsFromItsRows() {
        let outcome = Outcome(written: [], headline: "none", report: mixed, note: nil)

        #expect(outcome.all == outcome.allRows.map(\.text))
        #expect(outcome.collapsed == outcome.collapsedRows.map(\.text))
        #expect(outcome.findings(verbose: true) == outcome.all)
        #expect(outcome.findings(verbose: false) == outcome.collapsed)
        #expect(outcome.rows(verbose: true) == outcome.allRows)
    }

    @Test func aplanDerivesItsStringsFromItsRows() {
        let plan = StagedPlan(summary: SegmentationSummary(tracks: []), diagnostics: mixed)

        #expect(plan.all == plan.allRows.map(\.text))
        #expect(plan.collapsed == plan.collapsedRows.map(\.text))
        #expect(plan.findings(verbose: true) == plan.all)
        #expect(plan.rows(verbose: false) == plan.collapsedRows)
    }
}
