import Foundation
import KSPKit
import KSPRun
import Testing

@testable import KSPApp

@MainActor
@Suite struct AppModelSegmentationTests {
    private func model() -> AppModel {
        AppModel(
            store: FolderStore(defaults: volatileDefaults()),
            destination: { _, _ in
                Destination(directory: FileManager.default.temporaryDirectory, note: nil)
            },
            reveal: { _ in }, chooseFolder: { _ in nil })
    }

    private var midiFixture: URL {
        RepoData.projectFiles.appending(path: "m6-test-file.mid")
    }

    private var projectFixture: URL {
        RepoData.projectFiles.appending(path: "project_5.KeyStepPro")
    }

    private func segmentation(of model: AppModel) throws -> SegmentationSummary {
        guard case .ready(let summary) = try #require(model.staged).segmentation else {
            Issue.record("the staged MIDI file should have been segmented")
            throw CancellationError()
        }
        return summary
    }

    @Test func adroppedMIDIFileIsSegmentedFromTheRealPlanner() async throws {
        let model = model()
        model.accept(midiFixture)

        await model.segment()

        let summary = try segmentation(of: model)
        #expect(summary.tracks.map(\.deviceTrack) == [1, 2, 3, 4])
        #expect(summary.tracks.map(\.sourceTrack) == [3, 4, 5, 6])
        #expect(summary.tracks[3].isSplit)
    }

    /// The criterion that the view follows the selection rather than the drop.
    @Test func untickingAsourceTrackChangesWhatTheSegmentationSays() async throws {
        let model = model()
        model.accept(midiFixture)
        await model.summarise()
        await model.segment()
        #expect(try segmentation(of: model).tracks.count == 4)

        model.toggle(sourceTrack: 3)
        await model.segment()

        #expect(try segmentation(of: model).tracks.map(\.sourceTrack) == [4, 5, 6])
    }

    /// The criterion's other half: the view follows the routing as it follows the ticks.
    @Test func sendingAsourceTrackElsewhereChangesWhatTheSegmentationSays() async throws {
        let model = model()
        model.accept(midiFixture)
        await model.summarise()
        await model.segment()
        #expect(try segmentation(of: model).tracks.map(\.sourceTrack) == [3, 4, 5, 6])

        model.send(sourceTrack: 6, to: .track(1))
        await model.segment()

        #expect(try segmentation(of: model).tracks.map(\.sourceTrack) == [6, 3, 4, 5])
    }

    @Test func asegmentationArrivingAfterAcancelIsDropped() async throws {
        let model = model()
        model.accept(midiFixture)

        let planning = Task { await model.segment() }
        await Task.yield()
        model.cancel()
        await planning.value

        guard case .idle = model.phase else {
            Issue.record("a cancelled drop should have stayed cancelled")
            return
        }
    }

    /// A late answer for a selection the user has moved on from would show figures for the wrong
    /// set of tracks, which is the failure a preview exists to prevent.
    @Test func asegmentationArrivingAfterAtickIsDropped() async throws {
        let model = model()
        model.accept(midiFixture)
        await model.summarise()

        let planning = Task { await model.segment() }
        await Task.yield()
        model.toggle(sourceTrack: 3)
        await planning.value

        guard case .loading = try #require(model.staged).segmentation else {
            Issue.record("a segmentation for a stale selection should have been dropped")
            return
        }
    }

    @Test func adroppedProjectIsNotSegmented() async throws {
        let model = model()
        model.accept(projectFixture)

        await model.segment()

        guard case .loading = try #require(model.staged).segmentation else {
            Issue.record("a project drop has no import to segment")
            return
        }
    }

    @Test func afileThatCannotBePlannedShowsTheFailure() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let broken = directory.appending(path: "broken.mid")
        try Data("not a midi file".utf8).write(to: broken)
        let model = model()

        model.accept(broken)
        await model.segment()

        guard case .failed = try #require(model.staged).segmentation else {
            Issue.record("an unreadable MIDI file should have shown its failure")
            return
        }
    }
}
