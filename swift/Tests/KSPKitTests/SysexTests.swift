import Foundation
import Testing

@testable import KSPKit

@Suite struct SysexTests {
    @Test func aScalarRequestIsTheShortForm() throws {
        // Frame 13 of the capture: paramId 37, itemId 120, no indices.
        let request = ReadRequest(item: 120, param: 37)
        #expect(try hex(Sysex.buildReadRequest(request)) == "f000206b7f4201012578f7")
    }

    @Test func aThreeIndexRequestCarriesItsCount() throws {
        // 48 for track 1, pattern 1, slot 1, steps 17-32.
        let request = ReadRequest(item: 123, param: 48, indices: [1, 1, 17], count: 16)
        #expect(try hex(Sysex.buildReadRequest(request)) == "f000206b7f420b0130037b01011110f7")
    }

    @Test func aScalarReplyYieldsOneValue() throws {
        let (request, values) = try Sysex.parseReply(bytes("f000206b7f420201257803f7"))
        #expect(request == ReadRequest(item: 120, param: 37))
        #expect(values == [3])
    }

    @Test func aLongReplyYieldsExactlyCountValues() throws {
        let frame = bytes("f000206b7f420c01540379010501107f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7ff7")
        let (request, values) = try Sysex.parseReply(frame)
        #expect(request == ReadRequest(item: 121, param: 84, indices: [1, 5, 1], count: 16))
        #expect(values == Array(repeating: 127, count: 16))
    }

    @Test func theRoundTripIsExact() throws {
        // Build a request, dress it as the reply the device would send, parse it back to the
        // request we started from.
        let request = ReadRequest(item: 126, param: 50, indices: [16, 3, 49], count: 16)
        let frame = try Sysex.buildReadRequest(request)
        let reply =
            Array(frame[0..<6]) + [Sysex.cmdReadReply] + Array(frame[7..<(frame.count - 1)])
            + Array(repeating: UInt8(0), count: 16) + [Sysex.end]
        #expect(try Sysex.parseReply(reply).request == request)
    }

    @Test(
        arguments: [
            "f07e7f0601f7",  // universal identity, not our envelope
            "f000206b7f421c00f7",  // the ack, not a reply
            "f000206b7f420c01540379010501107f",  // truncated, no terminator
        ])
    func aFrameThatIsNotAReplyIsRefused(frame: String) {
        #expect(throws: KSPError.self) { try Sysex.parseReply(bytes(frame)) }
    }

    @Test func aReplyThatUnderdeliversIsRefused() {
        // The count byte is a promise.
        let frame = bytes("f000206b7f420c0130037b0101111001020304f7")
        let thrown = #expect(throws: KSPError.self) { try Sysex.parseReply(frame) }
        #expect(thrown == .value("reply carried 4 values, header promised 16"))
    }

    @Test func aReplyTooShortForItsOwnHeaderIsRefused() {
        // Python indexes past the end here and raises IndexError; the port refuses it as a value.
        let thrown = #expect(throws: KSPError.self) {
            try Sysex.parseReply(bytes("f000206b7f420cf7"))
        }
        #expect(thrown == .value("read reply ends inside its own header"))
    }

    @Test func theShortFormRefusesIndices() {
        let thrown = #expect(throws: KSPError.self) {
            try Sysex.buildReadRequest(ReadRequest(item: 120, param: 37, indices: [1]))
        }
        #expect(thrown == .value("the short form takes no indices"))
    }

    @Test func byte7CarriesTheSlotInTheShortForm() throws {
        // The same frame as the capture's 13, addressed at slot 2 instead.
        let request = ReadRequest(item: 120, param: 37)
        #expect(try hex(Sysex.buildReadRequest(request, slot: 2)) == "f000206b7f4201022578f7")
    }

    @Test func byte7CarriesTheSlotInTheLongForm() throws {
        let request = ReadRequest(item: 123, param: 48, indices: [1, 1, 17], count: 16)
        #expect(
            try hex(Sysex.buildReadRequest(request, slot: 2)) == "f000206b7f420b0230037b01011110f7")
    }

    @Test func theSlotDefaultsToOne() throws {
        let request = ReadRequest(item: 120, param: 37)
        #expect(try Sysex.buildReadRequest(request) == Sysex.buildReadRequest(request, slot: 1))
        #expect(Sysex.defaultSlot == 1)
    }

    @Test(arguments: [0, 17, 127])
    func aSlotOutsideTheSixteenStillBuilds(slot: Int) throws {
        // H4.1 asks the device what it does with 0 and with 17, so the codec must not be the thing
        // that refuses them.
        let request = ReadRequest(item: 120, param: 37)
        #expect(try Sysex.buildReadRequest(request, slot: slot)[7] == UInt8(slot))
    }

    @Test(arguments: [-1, 128])
    func aSlotOutsideSevenBitsIsRefused(slot: Int) {
        let request = ReadRequest(item: 120, param: 37)
        let thrown = #expect(throws: KSPError.self) {
            try Sysex.buildReadRequest(request, slot: slot)
        }
        #expect(thrown == .value("slot \(slot), expected 0 to 127"))
    }

    @Test func aRequestFieldWiderThanAByteIsRefused() {
        // Python's bytes() is what refuses these; the port has to say so itself.
        #expect(throws: KSPError.self) {
            try Sysex.buildReadRequest(ReadRequest(item: 300, param: 37))
        }
        #expect(throws: KSPError.self) {
            try Sysex.buildReadRequest(ReadRequest(item: 123, param: 48, indices: [-1], count: 1))
        }
    }

    @Test func aCountAboveTheDevicesCeilingIsRefused() {
        // Above it the device clamps and answers a different question.
        let thrown = #expect(throws: KSPError.self) {
            try Sysex.buildReadRequest(ReadRequest(item: 123, param: 48, indices: [1], count: 101))
        }
        #expect(thrown == .value("count 101, expected 0 to 100"))
    }

    @Test(arguments: [0, 4])
    func aRequestWithoutOneToThreeIndicesIsRefused(indexCount: Int) {
        let indices = Array(repeating: 1, count: indexCount)
        let thrown = #expect(throws: KSPError.self) {
            try Sysex.buildReadRequest(
                ReadRequest(item: 123, param: 48, indices: indices, count: 1))
        }
        #expect(thrown == .value("\(indexCount) indices, expected 1 to 3"))
    }

    @Test func theSlotComesBackOffAReply() throws {
        #expect(try Sysex.parseSlot(bytes("f000206b7f420201257803f7")) == 1)
        #expect(try Sysex.parseSlot(bytes("f000206b7f420202257803f7")) == 2)
    }

    @Test func aFrameThatIsTooShortHasNoSlot() {
        #expect(throws: KSPError.self) { try Sysex.parseSlot(bytes("f000206b7f42")) }
    }

    @Test func thePrologueNamesItsSlot() throws {
        // Spec 7.5: `05 <slot>` is the first frame of a read.
        #expect(try hex(Sysex.prologue()) == "f000206b7f420501f7")
        #expect(try hex(Sysex.prologue(2)) == "f000206b7f420502f7")
    }

    @Test(arguments: 1...16)
    func everySlotGetsThePrologueItNames(slot: Int) throws {
        #expect(try hex(Sysex.prologue(slot)) == "f000206b7f4205" + hex([UInt8(slot)]) + "f7")
    }

    @Test func theAckIsTheOneFrameWithoutASlot() {
        #expect(hex(Sysex.ack) == "f000206b7f421c00f7")
    }

    @Test func theIdentityRequestIsTheUniversalEnvelope() {
        // Frame 7 of the capture.
        #expect(hex(Sysex.identityRequest) == "f07e7f0601f7")
    }

    @Test func theIdentityReplyGivesTheFirmwareVersion() throws {
        #expect(try Sysex.parseIdentity(identityReply()) == "2.5.20")
    }

    @Test(
        arguments: [
            "f000206b7f420201257803f7",  // a read reply, not an identity one
            "f07e7f060200206b0200090025140502",  // no terminator
            "f07e7f06020001610200090025140502f7",  // a different manufacturer
            "f07e7f060200206b02000900251405f7",  // a byte short
        ])
    func aFrameThatIsNotAnIdentityReplyIsRefused(frame: String) {
        #expect(throws: KSPError.self) { try Sysex.parseIdentity(bytes(frame)) }
    }
}

/// Frame 9 of the capture, the device's answer to the identity request.
private func identityReply() throws -> [UInt8] {
    let capture = RepoData.root.appending(
        path: "usb_midi_investigation/sysex_until_project_1_track_1_pattern_1.jsonl")
    for line in try String(contentsOf: capture, encoding: .utf8).split(separator: "\n") {
        guard
            let frame = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            frame["frame_number"] as? Int == 9,
            let sysex = frame["sysex_hex"] as? String
        else { continue }
        return bytes(sysex)
    }
    throw KSPError.value("no frame 9 in \(capture.path)")
}

private func bytes(_ hex: String) -> [UInt8] {
    var frame: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        frame.append(UInt8(hex[index..<next], radix: 16) ?? 0)
        index = next
    }
    return frame
}

private func hex(_ frame: [UInt8]) -> String {
    frame.map { ($0 < 0x10 ? "0" : "") + String($0, radix: 16) }.joined()
}
