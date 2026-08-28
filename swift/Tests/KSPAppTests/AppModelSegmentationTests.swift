import Foundation
import KSPKit
import KSPMIDI
import KSPRun
import SwiftMIDIFile
import Testing

@testable import KSPApp

/// Six bars of quarter notes: long enough that the automatic split cuts it once, at 64 steps and
/// then 32, and short enough that the cut has somewhere legal to go on either side of that.
private func sixBarFile(in directory: URL) throws -> URL {
    var track = MusicalMIDI1File.Track()
    for _ in 0..<24 {
        track.events.append(.noteOn(note: 60, velocity: .midi1(100)))
        track.events.append(.noteOff(delta: .noteQuarter, note: 60, velocity: .midi1(0)))
    }
    let path = directory.appending(path: "six-bars.mid")
    try MusicalMIDI1File(
        format: .multipleTracksSynchronous,
        timebase: .init(ticksPerQuarterNote: KSPMIDI.defaultTicksPerQuarterNote),
        tracks: [track]
    ).rawData().write(to: path)
    return path
}

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

    /// A drop of the six-bar file, planned once, with the lane its one boundary sits in.
    private func dragged(_ directory: URL) async throws -> (model: AppModel, lane: SegmentLane) {
        let model = model()
        model.accept(try sixBarFile(in: directory))
        await model.summarise()
        await model.segment()
        let lane = try #require(SegmentLane(source: 1, summary: try segmentation(of: model)))
        #expect(lane.barCount == 6)
        #expect(lane.bars == [5])
        return (model, lane)
    }

    @Test func adraggedBoundaryCutsTheTrackWhereItWasPut() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, lane) = try await dragged(directory)

        model.move(sourceTrack: 1, handle: 0, toX: lane.x(ofBar: 4))
        await model.segment()

        let steps = try segmentation(of: model).tracks[0].segments.map(\.stepCount)
        #expect(steps == [48, 48])
        #expect(model.segmentationRefusal == nil)
        #expect(model.isSegmentationEdited)
    }

    /// The criterion that the boundaries reach the conversion through the CLI's own option
    /// rather than a second mechanism.
    @Test func thedraggedBoundariesAreWhatTheConversionRunsOn() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, lane) = try await dragged(directory)
        #expect(model.conversionSettings.segmentBarsSpec == nil)

        model.move(sourceTrack: 1, handle: 0, toX: lane.x(ofBar: 3))

        #expect(model.conversionSettings.segmentBarsSpec == "1:3")
    }

    /// Refused as it is made, in the planner's own words, with the last plan that worked still
    /// drawn: a preview that blanked on a bad drag would take the question away with the answer.
    @Test func aboundaryPastTheStepLimitIsRefusedAndPutBack() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, lane) = try await dragged(directory)

        model.move(sourceTrack: 1, handle: 0, toX: lane.x(ofBar: 6))
        #expect(model.conversionSettings.segmentBarsSpec == "1:6")
        await model.segment()

        #expect(model.segmentationRefusal?.contains("past the device's 64") == true)
        #expect(model.conversionSettings.segmentBarsSpec == nil)
        #expect(model.isSegmentationEdited == false)
        #expect(try segmentation(of: model).tracks[0].segments.map(\.stepCount) == [64, 32])
    }

    @Test func resetReturnsTheSegmentationToTheAutomaticSplit() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, lane) = try await dragged(directory)
        model.move(sourceTrack: 1, handle: 0, toX: lane.x(ofBar: 4))
        await model.segment()
        #expect(try segmentation(of: model).tracks[0].segments.map(\.stepCount) == [48, 48])

        model.resetSegmentation()
        await model.segment()

        #expect(try segmentation(of: model).tracks[0].segments.map(\.stepCount) == [64, 32])
        #expect(model.isSegmentationEdited == false)
        #expect(model.conversionSettings.segmentBarsSpec == nil)
    }

    /// Untouched, the run is the one that ran before: no spec at all, not a spec of the split the
    /// planner would have made anyway.
    @Test func anuntouchedPreviewNamesNoSegmentation() async throws {
        let model = model()
        model.accept(midiFixture)
        await model.summarise()
        await model.segment()

        #expect(model.conversionSettings.segmentBarsSpec == nil)
        #expect(model.isSegmentationEdited == false)
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
