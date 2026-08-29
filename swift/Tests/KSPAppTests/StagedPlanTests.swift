import Foundation
import KSPKit
import KSPRun
import Testing

@testable import KSPApp

@MainActor
@Suite struct StagedPlanTests {
    private func model(writingInto directory: URL) -> AppModel {
        AppModel(
            store: FolderStore(defaults: volatileDefaults()),
            settingsStore: advancedSettings(),
            destination: { _, _ in Destination(directory: directory, note: nil) },
            reveal: { _ in }, chooseFolder: { _ in nil })
    }

    private var midiFixture: URL { RepoData.projectFiles.appending(path: "m6-test-file.mid") }

    private func planned(_ state: SegmentationState) throws -> StagedPlan {
        guard case .ready(let plan) = state else {
            Issue.record("the plan is \(state), not ready")
            throw CancellationError()
        }
        return plan
    }

    /// The acceptance criterion: the findings the plan already produced arrive before the
    /// conversion does, rather than after it has run.
    @Test func aplannedImportCarriesTheFindingsItWouldRaise() async throws {
        let state = await Conversion.segment(.toProject(midiFixture), settings: Settings())

        let plan = try planned(state)
        #expect(!plan.all.isEmpty)
        #expect(plan.findings(verbose: false).count <= plan.all.count)
        #expect(plan.findings(verbose: true) == plan.all)
    }

    /// A real file through the runner the app calls: synthetic summaries prove the arithmetic,
    /// and only this proves the figures are the core's own.
    @Test func arealFileReadsAgainstAllFiveLimits() async throws {
        let state = await Conversion.segment(.toProject(midiFixture), settings: Settings())

        let limits = Limits(try planned(state).summary)

        #expect(
            limits.gauges.map(\.figure) == ["4 / 4", "2 / 16", "64 / 64", "160 / 192", "4 / 16"])
        // Four of four tracks and 64 of 64 steps are the device's capability, not a wall neared.
        #expect(limits.gauges.map(\.status) == [.within, .within, .within, .near, .within])
        #expect(
            limits.gauges.map(\.site) == [
                nil, "Track 4", "Track 1, pattern 1", "Track 2, pattern 1", "Track 2, pattern 1",
            ])
        // Four source tracks onto four device tracks: full, and nothing refused.
        #expect(limits.exceeded.isEmpty)
    }

    @Test func theStagedPlanCarriesTheSummaryTheGridDraws() async throws {
        let state = await Conversion.segment(.toProject(midiFixture), settings: Settings())

        let plan = try planned(state)
        #expect(plan.summary.tracks.map(\.sourceTrack) == [3, 4, 5, 6])
    }

    /// Rendered once rather than on every body evaluation, which is the reason it is stored.
    @Test func thefindingsAreRenderedOnceRatherThanOnEveryRead() {
        let report = Report([
            Diagnostic(code: .patternSplit, detail: "one", site: Site(track: 1)),
            Diagnostic(code: .patternSplit, detail: "two", site: Site(track: 2)),
        ])

        let plan = StagedPlan(summary: SegmentationSummary(tracks: []), diagnostics: report)

        #expect(plan.all.count == 2)
        #expect(plan.collapsed.count == 1)
    }

    @Test func aplanThatWillNotReadFailsRatherThanCarryingEmptyFindings() async {
        let missing = RepoData.projectFiles.appending(path: "no-such-file.mid")

        let state = await Conversion.segment(.toProject(missing), settings: Settings())

        guard case .failed(let message) = state else {
            Issue.record("an unreadable file should fail, not plan")
            return
        }
        #expect(!message.isEmpty)
    }

    /// A tick moves the plan, so it must move the findings with it: figures for one selection
    /// beside findings for another is the one thing a preview must never show.
    @Test func aselectionMovesTheFindingsWithTheFigures() async throws {
        let model = model(writingInto: try tempDirectory())
        model.accept(midiFixture)
        await model.summarise()

        await model.segment()
        let all = try planned(try #require(model.staged).segmentation)

        model.toggle(sourceTrack: 5)
        model.toggle(sourceTrack: 6)
        await model.segment()
        let fewer = try planned(try #require(model.staged).segmentation)

        #expect(all.summary.tracks.count == 4)
        #expect(fewer.summary.tracks.count == 2)
        #expect(fewer.all != all.all)
    }

    /// The limits are read off the plan the app is holding, so they move on the same tick.
    @Test func thelimitsFollowTheSelectionThePlanWasMadeFor() async throws {
        let model = model(writingInto: try tempDirectory())
        model.accept(midiFixture)
        await model.summarise()

        await model.segment()
        let all = Limits(try planned(try #require(model.staged).segmentation).summary)

        model.toggle(sourceTrack: 5)
        model.toggle(sourceTrack: 6)
        await model.segment()
        let fewer = Limits(try planned(try #require(model.staged).segmentation).summary)

        #expect(all.gauges[0].used == 4)
        #expect(fewer.gauges[0].used == 2)
    }
}
