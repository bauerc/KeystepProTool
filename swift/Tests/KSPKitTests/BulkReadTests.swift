import Foundation
import Testing

@testable import KSPKit

/// The request a frame carries. `Sysex` parses replies; only a fake device parses requests.
private func decodeRequest(_ frame: [UInt8]) throws -> ReadRequest {
    let body = Array(frame.dropFirst(6).dropLast())
    guard body.count >= 4 else { throw KSPError.value("\(hexString(frame)) is not a request") }
    if body[0] == Sysex.cmdScalar {
        return ReadRequest(item: Int(body[3]), param: Int(body[2]))
    }
    let indexCount = Int(body[3])
    guard body.count > 5 + indexCount else {
        throw KSPError.value("\(hexString(frame)) ends inside its own header")
    }
    return ReadRequest(
        item: Int(body[4]),
        param: Int(body[2]),
        indices: body[5..<(5 + indexCount)].map(Int.init),
        count: Int(body[5 + indexCount])
    )
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

/// Every address `tests/fixtures/recall_tape.txt` delivered, as the device sent it.
private func recallTape() throws -> [String: Int] {
    let path = RepoData.fixtures.appending(path: "recall_tape.txt")
    var values: [String: Int] = [:]
    for line in try String(contentsOf: path, encoding: .utf8).split(separator: "\n") {
        let fields = line.split(separator: " ")
        guard fields.count == 2 else { throw KSPError.value("\(line) is not <sent> <received>") }
        let (request, payload) = try Sysex.parseReply(hexBytes(String(fields[1])))
        guard request == (try decodeRequest(hexBytes(String(fields[0])))) else {
            throw KSPError.value("\(line) answers a different address than it asks")
        }
        for (name, value) in zip(try BulkRead.keysFor(request), payload) {
            values[name] = value
        }
    }
    return values
}

/// Answers any address from a tape's values, at any count the device allows.
private final class DeviceModel: Transport {
    private let values: [String: Int]
    /// What the walk put on the wire, which is what the gate is judged by.
    private(set) var asked: [ReadRequest] = []
    private(set) var slots: Set<Int> = []
    private(set) var sent: [[UInt8]] = []

    /// Answers everything with the filler byte, as a slot holding nothing saved does.
    private let filler: Bool
    /// Echoes this slot rather than the one asked about; nil echoes the slot asked about,
    /// which is what the walk's own check needs to pass.
    private let echoing: Int?

    init(_ values: [String: Int], filler: Bool = false, echoing: Int? = nil) {
        self.values = values
        self.filler = filler
        self.echoing = echoing
    }

    func send(_ frame: [UInt8]) throws {
        sent.append(frame)
    }

    func exchange(_ frame: [UInt8]) throws -> [UInt8] {
        let request = try decodeRequest(frame)
        asked.append(request)
        let slot = try Sysex.parseSlot(frame)
        slots.insert(slot)
        let names = try BulkRead.keysFor(request)
        guard !filler else {
            return buildReply(
                request, Array(repeating: BulkRead.filler, count: names.count),
                slot: echoing ?? slot)
        }
        let payload = try names.map { name in
            guard let value = values[name] else {
                throw KSPError.value("tape holds no value for \(name)")
            }
            return value
        }
        return buildReply(request, payload, slot: echoing ?? slot)
    }
}

/// `tests/fixtures/bulk_read_walk.txt`, written by `tools/gen_bulk_read_walk_fixture.py`.
private func pythonWalk() throws -> [ReadRequest] {
    let path = RepoData.fixtures.appending(path: "bulk_read_walk.txt")
    return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map { line in
        let fields = line.split(separator: " ")
        guard fields.count == 4 else {
            throw KSPError.value("\(line) is not <item> <param> <indices> <count>")
        }
        return ReadRequest(
            item: try number(fields[0]),
            param: try number(fields[1]),
            indices: fields[2] == "-" ? [] : try fields[2].split(separator: ",").map(number),
            count: fields[3] == "-" ? nil : try number(fields[3])
        )
    }
}

private func number(_ field: Substring) throws -> Int {
    guard let value = Int(field) else { throw KSPError.value("\(field) is not a number") }
    return value
}

/// The file's full key set, which the plan does not address all of.
private func templateKeys() throws -> [String] {
    Array(try Samples.raw("Default.KeyStepPro").keys)
}

@Suite struct BulkReadTests {
    @Test func theReplayReconstructsTheProjectExactly() throws {
        // 153,497 of 153,497: tape 1 is MCC recalling initial_project, so the walk owes the
        // file itself, not merely a plausible project.
        let replayed = try BulkRead.readRaw(
            DeviceModel(try recallTape()), templateKeys: try templateKeys())

        #expect(replayed == (try Samples.raw("initial_project.KeyStepPro")))
        #expect(replayed.count == 153_497)
    }

    @Test func theGateSkipsTheAddressesPythonSkips() throws {
        // Both cores asking 1,007 times is not both asking the same 1,007 times, and only the
        // second is the port being right.
        let device = DeviceModel(try recallTape())
        _ = try BulkRead.readRaw(device, templateKeys: [String]())
        let expected = try pythonWalk()

        #expect(device.asked.count == 1_007)
        #expect(device.asked.count == expected.count)
        let mismatch = zip(device.asked, expected).enumerated().first {
            $0.element.0 != $0.element.1
        }
        if let mismatch {
            Issue.record(
                """
                request \(mismatch.offset)
                  asked:    \(mismatch.element.0)
                  expected: \(mismatch.element.1)
                """)
        }
    }

    @Test func theGateNeverSkipsTheDrumPool() throws {
        // A dead drum entry reads 127 in some patterns and the default row in others, so
        // nothing derives it.
        let device = DeviceModel(try recallTape())
        _ = try BulkRead.readRaw(device, templateKeys: [String]())
        let pool = Set(
            try BulkFast.iterRequests().filter {
                (117...121).contains($0.param) && $0.indices.count == 3
            })

        #expect(!pool.isEmpty)
        #expect(pool.isSubset(of: Set(device.asked)))
    }

    @Test func everyUnaddressedKeyIsZeroFilled() throws {
        // The plan asks for the logical extent; the rest of the rectangle is zero in every
        // corpus file and is filled from the template rather than fetched.
        let addressed = Set(try BulkFast.iterRequests().flatMap(BulkRead.keysFor))
        let template = Set(try templateKeys()).subtracting(LenientJSON.leadingKeys)
        let replayed = try BulkRead.readRaw(
            DeviceModel(try recallTape()), templateKeys: try templateKeys())

        #expect(addressed.count == 117_783)
        #expect(template.subtracting(addressed).count == 35_712)
        #expect(template.subtracting(addressed).allSatisfy { replayed[$0] == .int(0) })
    }

    @Test func theUnsetSentinelBecomesWhatMccStores() throws {
        // The device sends 0xFF for an uninitialised pattern default pitch.
        let replayed = try BulkRead.readRaw(
            DeviceModel(try recallTape()), templateKeys: try templateKeys())
        let unset = replayed.filter { $0.value == .int(Sysex.unsetInFile) }.keys.sorted()

        #expect(unset == (1...13).map { "123_117_\($0)" }.sorted())
    }

    @Test func theMccSideConstantsAreNotTakenFromTheWire() throws {
        // These read 0 from hardware but are 127 in all six corpus files, including the
        // factory default, which never came off a device.
        let replayed = try BulkRead.readRaw(
            DeviceModel(try recallTape()), templateKeys: try templateKeys())

        #expect(BulkRead.mccConstants.allSatisfy { replayed[$0.key] == .int($0.value) })
    }

    @Test func theResultDecodesThroughTheExistingReader() throws {
        // The point of the whole exercise: the hardware becomes a second producer of the
        // dictionary LenientJSON already produces, and nothing downstream changes.
        let replayed = try BulkRead.readRaw(
            DeviceModel(try recallTape()), templateKeys: try templateKeys())
        let project = try Reader.readProject(replayed, sourceName: "replay")

        #expect(project.tracks.count == 4)
    }

    @Test func theSlotIsSelectedBeforeAnythingIsRead() throws {
        // `05 <slot>` is what chooses the project; byte 7 then agrees with it.
        let device = DeviceModel(try recallTape())
        _ = try BulkRead.readRaw(device, templateKeys: [String](), slot: 2)

        #expect(device.sent == [try Sysex.prologue(2)])
        #expect(device.slots == [2])
    }

    @Test func aSlotTheDeviceWillNotServeIsRefused() throws {
        // Some slots answer a read with filler rather than a project (observed 2026-08-14;
        // which slots and why is not established).
        let device = DeviceModel(try recallTape(), filler: true)
        let thrown = #expect(throws: KSPError.self) {
            try BulkRead.readRaw(device, templateKeys: [String](), slot: 3)
        }

        #expect(
            thrown
                == .value(
                    "the device answered 120_37 with 0x7f, the filler byte, rather than a value "
                        + "any project holds: it is not returning slot 3's contents. The usual "
                        + "cause is slot 3 never having been saved on the device."))
        #expect(device.asked.count == 1)
        // Selecting slot 1 while reading slot 3 would read the wrong project.
        #expect(device.sent == [try Sysex.prologue(3)])
    }

    @Test func theEchoedSlotIsCheckedBeforeThePayload() throws {
        // The device's real refusal echoes the slot it was asked about, so a reply naming a
        // slot nobody asked for is a different fault and says so.
        let device = DeviceModel(try recallTape(), filler: true, echoing: 3)
        let thrown = #expect(throws: KSPError.self) {
            try BulkRead.readRaw(device, templateKeys: [String]())
        }

        #expect(thrown == .value("asked slot 1, device answered slot 3"))
    }

    @Test func aRealSlotProbeValuePassesTheGuard() throws {
        // 0-3 is the corpus range for 120_37, so the guard cannot fire on a project the
        // device is genuinely serving.
        let replayed = try BulkRead.readRaw(DeviceModel(try recallTape()), templateKeys: [String]())

        #expect(replayed[BulkRead.slotProbe] != .int(BulkRead.filler))
    }

    @Test func aReplyAboutAnotherSlotIsRefused() throws {
        // Merging two projects into one file is the failure this catches, and it is silent.
        let device = DeviceModel(try recallTape(), echoing: 3)
        let thrown = #expect(throws: KSPError.self) {
            try BulkRead.readRaw(device, templateKeys: [String]())
        }

        #expect(thrown == .value("asked slot 1, device answered slot 3"))
    }

    @Test func aDeviceThatAnswersTheWrongAddressIsRefused() throws {
        // The reply echoes the request header, so a desynchronised stream is detectable --
        // and silently accepting it would write values under the wrong keys.
        let thrown = #expect(throws: KSPError.self) {
            try BulkRead.readRaw(Desynchronised(), templateKeys: [String]())
        }

        #expect(
            thrown
                == .value(
                    "asked for ReadRequest(item=120, param=37, indices=(), count=None), device "
                        + "answered ReadRequest(item=120, param=70, indices=(), count=None)"))
    }
}

/// Answers the first request with the reply to the second, as a dropped frame would.
private struct Desynchronised: Transport {
    func send(_ frame: [UInt8]) throws {}

    func exchange(_ frame: [UInt8]) throws -> [UInt8] {
        buildReply(ReadRequest(item: 120, param: 70), [0], slot: Sysex.defaultSlot)
    }
}
