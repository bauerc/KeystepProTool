import Foundation
import KSPKit
import KSPRun
import Testing

@testable import KSPApp

/// What the read handed the runner, and the answer it was given back. Unchecked because the
/// runner is called off the main actor: the options are written there and read here.
private final class PullLog: @unchecked Sendable {
    private let lock = NSLock()
    private var options: [PullRunner.Options] = []
    private let answer: RunResult

    init(answering answer: RunResult = RunResult()) {
        self.answer = answer
    }

    var asked: [PullRunner.Options] { lock.withLock { options } }

    func pull(_ received: PullRunner.Options) -> RunResult {
        lock.withLock { options.append(received) }
        return answer
    }
}

/// What the model revealed in the Finder, for the reason ``AppModelTests`` keeps its own.
private final class Revealed {
    var files: [[URL]] = []
}

@MainActor
@Suite struct DeviceReadTests {
    private func model(
        writingInto directory: URL, revealing log: Revealed = Revealed(),
        chosenMIDIFolder: URL? = nil,
        pull: @escaping @Sendable (PullRunner.Options) -> RunResult = { _ in RunResult() }
    ) -> AppModel {
        // The folder rather than an injected destination: a read follows the app's own
        // project-folder rule, so the rule is what the test has to set.
        let defaults = volatileDefaults()
        FolderStore(defaults: defaults).save(Folders(project: directory, midi: nil))
        return AppModel(
            store: FolderStore(defaults: defaults), settingsStore: advancedSettings(),
            reveal: { log.files.append($0) }, chooseFolder: { _ in chosenMIDIFolder },
            pull: pull)
    }

    /// A canned run, worded as `PullRunner` words its own.
    private func read(_ written: [URL], slot: Int = 1) -> RunResult {
        RunResult(
            stdout: """
                read slot \(slot) in 4.1 s, 1007 requests
                wrote \(written[0].relativePath)
                  817 note(s), 132 BPM
                  4.4 s total, 4.1 s of it at the device
                """, destinations: written)
    }

    @Test func areadIsNamedAfterTheProjectItTakes() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)

        model.slot = 3

        let plan = model.deviceReadPlan
        #expect(plan.slot == 3)
        #expect(plan.target == directory.appending(path: "Project 3.KeyStepPro"))
        #expect(plan.note == nil)
    }

    @Test func atypedNameWinsOverTheProjectsOwn() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)

        model.readName = "Live set"

        #expect(
            model.deviceReadPlan.target == directory.appending(path: "Live set.KeyStepPro"))
    }

    /// The runner refuses the whole read when either file is already there, so a free
    /// `.KeyStepPro` beside a taken `.mid` is not a free name.
    @Test func bothFilesMoveAlongTogetherWhenEitherNameIsTaken() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        try touch(directory, "Project 1.mid")

        model.alsoMidi = true

        let moved = model.deviceReadPlan
        #expect(moved.target == directory.appending(path: "Project 1 2.KeyStepPro"))
        #expect(moved.note?.contains("Project 1 2.KeyStepPro") == true)

        model.alsoMidi = false

        #expect(model.deviceReadPlan.target == directory.appending(path: "Project 1.KeyStepPro"))
    }

    @Test func thedestinationsOwnNoteReachesTheCard() {
        let plan = DeviceRead.plan(
            slot: 1, named: "",
            into: Destination(directory: URL(filePath: "/tmp"), note: "This went to Downloads."),
            alsoMidi: false, exists: { _ in false })

        #expect(plan.note == "This went to Downloads.")
    }

    @Test func therunnerIsHandedTheProjectAndTheDestinationAndNothingElse() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "Project 7.KeyStepPro")
        let log = PullLog(answering: read([target], slot: 7))
        let model = model(writingInto: directory, pull: log.pull)
        model.slot = 7
        model.alsoMidi = true

        await model.read()

        let asked = try #require(log.asked.first)
        #expect(log.asked.count == 1)
        #expect(asked.slot == 7)
        #expect(asked.output == target)
        #expect(asked.alsoMidi)
        // A free name was found, so the runner's overwrite guard is a backstop, not the rule.
        #expect(!asked.force)
        #expect(!asked.quiet)
        #expect(asked.template == nil)
    }

    @Test func whatCameBackIsTheRunnersOwnSummaryWithoutThePathsTheWindowLists() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "Project 1.KeyStepPro")
        let model = model(writingInto: directory, pull: PullLog(answering: read([target])).pull)

        await model.read()

        guard case .done(let outcome) = model.phase else {
            Issue.record("the read should have finished")
            return
        }
        #expect(
            outcome.headline == """
                read slot 1 in 4.1 s, 1007 requests
                817 note(s), 132 BPM
                4.4 s total, 4.1 s of it at the device
                """)
    }

    @Test func areadRevealsBothFilesAndOffersAnother() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appending(path: "Project 1.KeyStepPro")
        let midi = directory.appending(path: "Project 1.mid")
        let revealed = Revealed()
        let model = model(
            writingInto: directory, revealing: revealed,
            pull: PullLog(answering: read([project, midi])).pull)
        model.alsoMidi = true

        await model.read()

        guard case .done(let outcome) = model.phase else {
            Issue.record("the read should have finished")
            return
        }
        #expect(outcome.written == [project, midi])
        #expect(outcome.resultLine == "2 files written")
        #expect(outcome.againLabel == "Read another")
        #expect(revealed.files == [[project, midi]])
    }

    /// The runner's messages name the fix -- the cable, MIDI Control Center, `killall MIDIServer`,
    /// a project with nothing saved in it -- so the window says them rather than its own.
    @Test func afailedReadKeepsTheRunnersOwnWordsAndRevealsNothing() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mute =
            "the KeyStep Pro is not answering -- quit MIDI Control Center, and if that does not "
            + "help, run 'killall MIDIServer'"
        let revealed = Revealed()
        let model = model(
            writingInto: directory, revealing: revealed,
            pull: PullLog(answering: .failure(PullRunner.prog, mute, code: 1)).pull)

        await model.read()

        guard case .done(let outcome) = model.phase else {
            Issue.record("the read should have finished")
            return
        }
        #expect(outcome.failed)
        #expect(outcome.headline == mute)
        #expect(outcome.resultLine == "Nothing was read")
        #expect(revealed.files.isEmpty)
    }

    /// Through the real runner, which is what refuses a device it cannot reach -- and refuses it
    /// before anything is written.
    @Test func thedeviceIsReachedThroughTheRunnerRatherThanAroundIt() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = "no MIDI device named \"KeyStep Pro\""
        let model = model(
            writingInto: directory,
            pull: { PullRunner.run($0, attach: { throw KSPError.value(missing) }) })

        await model.read()

        guard case .done(let outcome) = model.phase else {
            Issue.record("the read should have finished")
            return
        }
        #expect(outcome.failed)
        #expect(outcome.headline.contains(missing))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    /// A drop staged mid-read would be thrown away by the read's own answer, which lands last.
    @Test func adropIsIgnoredWhileTheDeviceIsBeingRead() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory)
        model.phase = .reading(4)

        model.accept(RepoData.projectFiles.appending(path: "m6-test-file.mid"))

        #expect(model.staged == nil)
        guard case .reading(let slot) = model.phase else {
            Issue.record("the read should still be in flight")
            return
        }
        #expect(slot == 4)
    }

    @Test func themidiFolderIsNotedAsTheOneRuleAReadDoesNotFollow() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let elsewhere = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let model = model(writingInto: directory, chosenMIDIFolder: elsewhere)

        #expect(model.deviceMIDINote == nil)

        model.alsoMidi = true

        // Still nothing until a folder is chosen: the default already is beside the project.
        #expect(model.deviceMIDINote == nil)

        model.choose(.midi)

        #expect(model.deviceMIDINote?.contains("beside the project") == true)
    }

    @Test func theprojectAndTheMidiFlagSurviveALaunch() {
        withVolatileDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            #expect(store.loadSlot() == Sysex.defaultSlot)
            #expect(!store.loadAlsoMidi())

            store.save(slot: 12)
            store.save(alsoMidi: true)

            #expect(SettingsStore(defaults: defaults).loadSlot() == 12)
            #expect(SettingsStore(defaults: defaults).loadAlsoMidi())

            store.save(slot: Constants.projectSlots + 1)

            #expect(SettingsStore(defaults: defaults).loadSlot() == Sysex.defaultSlot)
        }
    }

    /// The stub stands in for the runner's write, so the preview reads a real project back.
    private func writing(_ fixture: String) -> @Sendable (PullRunner.Options) -> RunResult {
        let source = RepoData.projectFiles.appending(path: fixture)
        return { options in
            try? FileManager.default.copyItem(at: source, to: options.output)
            return RunResult(
                stdout: "read slot 1 in 4.1 s, 1007 requests", destinations: [options.output])
        }
    }

    @Test func thepreviewIsOfTheProjectTheReadWroteRatherThanOfTheWalk() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory, pull: writing("project_5.KeyStepPro"))
        let expected = try summarise("project_5.KeyStepPro")

        await model.read()

        let pending = try #require(model.readPreview)
        #expect(pending.project == directory.appending(path: "Project 1.KeyStepPro"))
        #expect(pending.summary == .loading)

        await model.previewRead()

        guard case .project(let shown) = model.readPreview?.summary else {
            Issue.record("the project the read wrote should have been summarised")
            return
        }
        #expect(shown.tempoBPM == expected.tempoBPM)
        #expect(shown.tracks.count == expected.tracks.count)
        // Named after the file it was read back from, not after the fixture it was copied from.
        #expect(shown.sourceName == "Project 1.KeyStepPro")
        guard case .ready = model.readPreview?.arrangement else {
            Issue.record("the patterns should have been laid out")
            return
        }
    }

    @Test func afailedReadPreviewsNothing() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(
            writingInto: directory,
            pull: PullLog(answering: .failure(PullRunner.prog, "not answering", code: 1)).pull)

        await model.read()

        #expect(model.readPreview == nil)
    }

    @Test func adropAfterAreadReplacesTheResultAndItsPreview() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(writingInto: directory, pull: writing("project_5.KeyStepPro"))
        await model.read()
        #expect(model.readPreview != nil)

        model.accept(RepoData.projectFiles.appending(path: "m6-test-file.mid"))

        #expect(model.readPreview == nil)
        #expect(model.staged != nil)
    }

    /// The picker's projects are the device's, and `pull --slot` validates against the same count.
    @Test func thepickerCoversTheDevicesOwnSixteen() {
        #expect(DeviceRead.slots.count == Constants.projectSlots)
        #expect(DeviceRead.slots.lowerBound == Sysex.defaultSlot)
        #expect(DeviceRead.defaultStem(slot: 16) == "Project 16")
    }
}
