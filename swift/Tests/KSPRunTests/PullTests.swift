import Foundation
import KSPKit
import Testing

@testable import KSPRun

/// `ksp-swift-cli pull` end to end, over the captured exchange rather than over the device.
@Suite struct PullTests {
    @Test func theProjectIsByteIdenticalToMCCsExport() throws {
        let device = TapeDevice(try recallTape())
        let written = try scratch()
        defer { try? FileManager.default.removeItem(at: written) }

        let result = PullRunner.run(PullRunner.Options(output: written), attach: { device })

        #expect(result.code == 0)
        let exported = RepoData.projectFiles.appending(path: "initial_project.KeyStepPro")
        let expected = LenientJSON.strippingTrailingComma(try Data(contentsOf: exported))
        #expect(try Data(contentsOf: written) == expected)
    }

    @Test func theWalkIsTheCoalescedOneAndTheSummaryReportsIt() throws {
        let device = TapeDevice(try recallTape())
        let written = try scratch()
        defer { try? FileManager.default.removeItem(at: written) }

        let result = PullRunner.run(PullRunner.Options(output: written), attach: { device })

        // The gated walk's own figure for this tape, which `bulk_read_walk.txt` pins too.
        #expect(device.asked.count == 1007)
        #expect(result.stdout.hasPrefix("read slot 1 in "))
        // The identity request is outside the count: 1,007 is the number spec 7.8 states.
        #expect(result.stdout.contains(", 1007 requests\n"))
        #expect(result.stdout.contains("\n  817 note(s), 132 BPM\n"))
        #expect(result.stdout.hasSuffix(" s of it at the device"))
    }

    @Test func theSlotIsChosenWithoutTouchingThePanel() throws {
        let device = TapeDevice(try recallTape(named: "recall_project_2_tape.txt"))
        let written = try scratch()
        defer { try? FileManager.default.removeItem(at: written) }

        let result = PullRunner.run(
            PullRunner.Options(output: written, slot: 2), attach: { device })

        #expect(result.code == 0)
        #expect(device.sent == [try Sysex.prologue(2)])
        #expect(result.stdout.hasPrefix("read slot 2 in "))
    }

    @Test func theVersionComesOffTheWire() throws {
        let device = TapeDevice(try recallTape())
        let written = try scratch()
        defer { try? FileManager.default.removeItem(at: written) }

        #expect(PullRunner.run(PullRunner.Options(output: written), attach: { device }).code == 0)

        #expect(device.identified == 1)
        #expect(try LenientJSON.load(contentsOf: written)["version"] == .string("2.5.20"))
    }

    @Test func noIdentityFallsBackWithoutAsking() throws {
        let device = TapeDevice(try recallTape())
        let written = try scratch()
        defer { try? FileManager.default.removeItem(at: written) }

        let result = PullRunner.run(
            PullRunner.Options(output: written, noIdentity: true), attach: { device })

        #expect(result.code == 0)
        #expect(device.identified == 0)
        #expect(try LenientJSON.load(contentsOf: written)["version"] == .string("2.5.20"))
    }

    @Test func anExistingFileIsNotOverwrittenWithoutForce() throws {
        let device = TapeDevice(try recallTape())
        let written = try tempFile("mine", suffix: ".KeyStepPro")
        defer { try? FileManager.default.removeItem(at: written) }

        let result = PullRunner.run(PullRunner.Options(output: written), attach: { device })

        #expect(result.code == 1)
        #expect(
            result.message == "\(written.relativePath) already exists (use --force to overwrite)")
        // The check is worth more before the read: ten seconds of the operator's attention.
        #expect(device.asked.isEmpty)
        #expect(try String(contentsOf: written, encoding: .utf8) == "mine")

        #expect(
            PullRunner.run(PullRunner.Options(output: written, force: true), attach: { device })
                .code == 0)
        #expect(try String(contentsOf: written, encoding: .utf8) != "mine")
    }

    @Test func anUnreadableTemplateStopsBeforeTheDevice() throws {
        let device = TapeDevice(try recallTape())
        let written = try scratch()
        defer { try? FileManager.default.removeItem(at: written) }

        let result = PullRunner.run(
            PullRunner.Options(
                output: written, template: URL(filePath: "/nonexistent/nowhere.KeyStepPro")),
            attach: { device })

        #expect(result.code == 1)
        #expect(result.stderr.hasPrefix("ksp-swift-cli pull: template: "))
        #expect(device.asked.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: written.path))
    }

    @Test func aSlotWithNothingSavedInItIsRefused() throws {
        // Filler parses as a valid empty project, so it has to be caught at the wire.
        let device = TapeDevice(try recallTape(), filler: true)
        let written = try scratch()
        defer { try? FileManager.default.removeItem(at: written) }

        let result = PullRunner.run(
            PullRunner.Options(output: written, slot: 3), attach: { device })

        #expect(result.code == 1)
        #expect(result.stderr.hasPrefix("ksp-swift-cli pull: slot 3: "))
        #expect(!FileManager.default.fileExists(atPath: written.path))
    }

    @Test func aDeviceThatIsNotThereFailsWithItsOwnMessage() throws {
        let written = try scratch()
        defer { try? FileManager.default.removeItem(at: written) }

        let result = PullRunner.run(PullRunner.Options(output: written)) {
            throw DeviceUnreachable()
        }

        #expect(result.code == 1)
        #expect(result.stderr.hasPrefix("ksp-swift-cli pull: "))
        #expect(!FileManager.default.fileExists(atPath: written.path))
    }

    @Test func alsoMidiWritesTheProjectAndItsMidiFromOneRead() throws {
        let device = TapeDevice(try recallTape())
        let written = try scratch()
        defer { try? FileManager.default.removeItem(at: written.deletingLastPathComponent()) }

        let result = PullRunner.run(
            PullRunner.Options(output: written, alsoMidi: true, configPath: noPersonalConfig),
            attach: { device })

        #expect(result.code == 0)
        #expect(FileManager.default.fileExists(atPath: written.path))
        #expect(FileManager.default.fileExists(atPath: midiBeside(written).path))
        #expect(device.asked.count == 1007)
    }

    /// `--also-midi` composes the two commands; it does not export differently.
    @Test(arguments: [1, 2]) func theExportedMidiIsTheFileExportWouldHaveWritten(slot: Int) throws {
        let tape = slot == 1 ? "recall_tape.txt" : "recall_project_2_tape.txt"
        let device = TapeDevice(try recallTape(named: tape))
        let composed = try scratch()
        defer { try? FileManager.default.removeItem(at: composed.deletingLastPathComponent()) }

        #expect(
            PullRunner.run(
                PullRunner.Options(
                    output: composed, slot: slot, alsoMidi: true, configPath: noPersonalConfig),
                attach: { device }
            ).code == 0)

        let separate = composed.deletingLastPathComponent().appending(path: "separate.mid")
        #expect(
            ExportRunner.run(
                ExportRunner.Options(path: composed, output: separate, configPath: noPersonalConfig)
            ).code == 0)

        #expect(try Data(contentsOf: midiBeside(composed)) == (try Data(contentsOf: separate)))
    }

    @Test func alsoMidiNamesBothFilesInTheSummary() throws {
        let device = TapeDevice(try recallTape())
        let written = try scratch()
        defer { try? FileManager.default.removeItem(at: written.deletingLastPathComponent()) }

        let result = PullRunner.run(
            PullRunner.Options(output: written, alsoMidi: true, configPath: noPersonalConfig),
            attach: { device })

        #expect(result.stdout.contains("wrote \(written.relativePath)\n"))
        #expect(result.stdout.contains("wrote \(midiBeside(written).relativePath)\n"))
        #expect(result.stdout.contains("note(s) from pattern(s) "))
        // The timing line stays last, whatever the export put in front of it.
        #expect(result.stdout.hasSuffix(" s of it at the device"))
    }

    /// Both destinations are checked before the device is touched, and --force covers both.
    @Test func anExistingMidiStopsTheReadTheWayAnExistingProjectDoes() throws {
        let device = TapeDevice(try recallTape())
        let written = try scratch()
        let midi = midiBeside(written)
        try FileManager.default.createDirectory(
            at: written.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "mine".write(to: midi, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: written.deletingLastPathComponent()) }

        let refused = PullRunner.run(
            PullRunner.Options(output: written, alsoMidi: true, configPath: noPersonalConfig),
            attach: { device })

        #expect(refused.code == 1)
        #expect(refused.message == "\(midi.relativePath) already exists (use --force to overwrite)")
        #expect(!FileManager.default.fileExists(atPath: written.path))
        #expect(try Data(contentsOf: midi) == Data("mine".utf8))
        #expect(device.asked.isEmpty)

        #expect(
            PullRunner.run(
                PullRunner.Options(
                    output: written, alsoMidi: true, force: true, configPath: noPersonalConfig),
                attach: { device }
            ).code == 0)
        #expect(try Data(contentsOf: midi) != Data("mine".utf8))
    }

    /// The read is worth keeping; a MIDI file with nothing in it would look like success.
    @Test func aProjectWithNoNotesKeepsThePullAndRefusesTheMidi() throws {
        let device = TapeDevice(try templateValues())
        let written = try scratch()
        defer { try? FileManager.default.removeItem(at: written.deletingLastPathComponent()) }

        let result = PullRunner.run(
            PullRunner.Options(output: written, alsoMidi: true, configPath: noPersonalConfig),
            attach: { device })

        #expect(result.code == 1)
        #expect(result.stderr.contains("no pattern holds notes"))
        #expect(FileManager.default.fileExists(atPath: written.path))
        #expect(!FileManager.default.fileExists(atPath: midiBeside(written).path))
    }

    /// Naming the project .mid would have the export overwrite the project.
    @Test func alsoMidiRefusesADestinationThatIsItsOwnMidiFile() throws {
        let device = TapeDevice(try recallTape())
        let written = try scratch().deletingPathExtension().appendingPathExtension("mid")
        defer { try? FileManager.default.removeItem(at: written.deletingLastPathComponent()) }

        let result = PullRunner.run(
            PullRunner.Options(output: written, alsoMidi: true, configPath: noPersonalConfig),
            attach: { device })

        #expect(result.code == 2)
        #expect(result.stderr.contains("same file"))
        #expect(!FileManager.default.fileExists(atPath: written.path))
        #expect(device.asked.isEmpty)
    }

    @Test func quietWritesTheProjectAndNoSummary() throws {
        let device = TapeDevice(try recallTape())
        let written = try scratch()
        defer { try? FileManager.default.removeItem(at: written) }

        let result = PullRunner.run(
            PullRunner.Options(output: written, quiet: true), attach: { device })

        #expect(result.code == 0)
        #expect(result.stdout.isEmpty)
        #expect(FileManager.default.fileExists(atPath: written.path))
    }
}

/// Where `--also-midi` puts the export: beside the project, suffixed `.mid`.
private func midiBeside(_ output: URL) -> URL {
    output.deletingPathExtension().appendingPathExtension("mid")
}

/// The factory default's parameters -- a saved project that holds no notes.
private func templateValues() throws -> [String: Int] {
    guard let path = ConvertRunner.defaultTemplate() else {
        throw KSPError.value("the bundled factory default is missing")
    }
    return try LenientJSON.load(contentsOf: path).compactMapValues {
        if case .int(let value) = $0 { value } else { nil }
    }
}

/// A destination that does not exist yet, in a directory the run has to create.
private func scratch() throws -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "ksp-pull-\(UUID().uuidString)")
        .appending(path: "pulled.KeyStepPro")
}

private struct DeviceUnreachable: Error, CustomStringConvertible {
    let description = "no MIDI device named \"KeyStep Pro\""
}

/// The request a frame carries. `Sysex` parses replies; only a fake device parses requests.
private func decodeRequest(_ frame: [UInt8]) throws -> ReadRequest {
    let body = Array(frame.dropFirst(Sysex.header.count).dropLast())
    if body[0] == Sysex.cmdScalar {
        return ReadRequest(item: Int(body[3]), param: Int(body[2]))
    }
    let indexCount = Int(body[3])
    return ReadRequest(
        item: Int(body[4]), param: Int(body[2]),
        indices: body[5..<(5 + indexCount)].map(Int.init), count: Int(body[5 + indexCount]))
}

private func buildReply(_ request: ReadRequest, _ values: [Int], slot: Int) -> [UInt8] {
    let body: [Int]
    if request.count == nil {
        body = [Int(Sysex.cmdScalarReply), slot, request.param, request.item] + values
    } else {
        body =
            [Int(Sysex.cmdReadReply), slot, request.param, request.indices.count, request.item]
            + request.indices + [request.count ?? 0] + values
    }
    return Sysex.header + body.map { UInt8($0) } + [Sysex.end]
}

private func hexBytes(_ text: some StringProtocol) -> [UInt8] {
    stride(from: 0, to: text.count, by: 2).map { offset in
        let start = text.index(text.startIndex, offsetBy: offset)
        return UInt8(text[start...text.index(after: start)], radix: 16) ?? 0
    }
}

/// Every address one of `tests/fixtures/*_tape.txt` delivered, as the device sent it.
private func recallTape(named name: String = "recall_tape.txt") throws -> [String: Int] {
    let path = RepoData.fixtures.appending(path: name)
    var values: [String: Int] = [:]
    for line in try String(contentsOf: path, encoding: .utf8).split(separator: "\n") {
        let fields = line.split(separator: " ")
        let (request, payload) = try Sysex.parseReply(hexBytes(fields[1]))
        for (name, value) in zip(try BulkRead.keysFor(request), payload) {
            values[name] = value
        }
    }
    return values
}

/// Answers any address from a tape's values, at any count the device allows.
private final class TapeDevice: PullDevice {
    private let values: [String: Int]
    /// Answers everything with the filler byte, as a slot holding nothing saved does.
    private let filler: Bool

    private(set) var asked: [ReadRequest] = []
    private(set) var sent: [[UInt8]] = []
    private(set) var identified = 0

    init(_ values: [String: Int], filler: Bool = false) {
        self.values = values
        self.filler = filler
    }

    func identify() throws -> String {
        identified += 1
        return Constants.projectVersion
    }

    func send(_ frame: [UInt8]) throws {
        sent.append(frame)
    }

    func exchange(_ frame: [UInt8]) throws -> [UInt8] {
        let request = try decodeRequest(frame)
        asked.append(request)
        // Echo the slot asked about, so the walk's own check of it is exercised.
        let echoed = try Sysex.parseSlot(frame)
        let names = try BulkRead.keysFor(request)
        if filler {
            let payload = Array(repeating: BulkRead.filler, count: names.count)
            return buildReply(request, payload, slot: echoed)
        }
        let payload = try names.map { name in
            guard let value = values[name] else {
                throw KSPError.value("the tape holds no value for \(name)")
            }
            return value
        }
        return buildReply(request, payload, slot: echoed)
    }
}
