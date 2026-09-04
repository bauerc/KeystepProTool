import KSPKit
import Testing

@testable import KSPDevice

/// Measured on hardware 2026-09-04: the device's answer to the identity request.
private let identityReply = "f07e7f060200206b0200090025140502f7"

@Suite struct DeviceTransportTests {
    private func port(answering answer: @escaping ([UInt8]) -> [[UInt8]]) -> ScriptedPort {
        ScriptedPort(answer: answer)
    }

    @Test func theTimeoutIsPythons() {
        // ksp_cli.usb_transport.DEFAULT_TIMEOUT_MS, so both cores wait the same.
        #expect(DeviceTransport.defaultTimeoutMs == 1000)
    }

    @Test func aReplyComesBackAndTheAckIsConsumed() throws {
        let request = try patternRequest(from: 14, count: 3)
        let answer = reply(to: request, values: [60, 60, 60])
        let wire = port { _ in [answer, Sysex.ack] }
        let device = DeviceTransport(port: wire, timeoutMs: 50)

        #expect(try device.exchange(request) == answer)
        // The ack ended the transaction rather than being left to answer the next one.
        #expect(try device.exchange(request) == answer)
        #expect(device.exchanges == 2)
    }

    @Test func silenceNamesTheFrameAndTheWait() throws {
        let request = try patternRequest(from: 1, count: 16)
        let device = DeviceTransport(port: port { _ in [] }, timeoutMs: 250)

        #expect(throws: DeviceError.noReply(to: request, within: 250)) {
            try device.exchange(request)
        }
    }

    @Test func anAckAloneIsNoReply() throws {
        let request = try patternRequest(from: 1, count: 16)
        let device = DeviceTransport(port: port { _ in [Sysex.ack] }, timeoutMs: 50)

        #expect(throws: DeviceError.self) { try device.exchange(request) }
    }

    @Test func twoRepliesToOneRequestAreRefused() throws {
        let request = try patternRequest(from: 14, count: 3)
        let answer = reply(to: request, values: [60, 60, 60])
        let device = DeviceTransport(
            port: port { _ in [answer, answer, Sysex.ack] }, timeoutMs: 50)

        #expect(throws: DeviceError.manyReplies(to: request, [answer, answer])) {
            try device.exchange(request)
        }
    }

    @Test func aFrameLeftOverFromAnEarlierRunCannotAnswer() throws {
        let request = try patternRequest(from: 14, count: 3)
        let answer = reply(to: request, values: [60, 60, 60])
        let stale = reply(to: try patternRequest(from: 1, count: 3), values: [1, 2, 3])
        let wire = port { _ in [answer, Sysex.ack] }
        wire.preload([stale])

        #expect(try DeviceTransport(port: wire, timeoutMs: 50).exchange(request) == answer)
    }

    @Test func truncationIsRepairedBeforeTheWalkSeesIt() throws {
        let request = try patternRequest(from: 1, count: 16)
        let wire = port { frame in [answerFromPatterns(frame), Sysex.ack] }
        let device = DeviceTransport(port: wire, timeoutMs: 50)

        let (answered, values) = try Sysex.parseReply(device.exchange(request))
        #expect(answered == ReadRequest(item: 123, param: 117, indices: [1], count: 16))
        #expect(values == sentinelPatterns.map(Int.init))
        #expect(device.repairs == 13)
        // Thirteen re-reads on top of the one request the walk asked for.
        #expect(device.exchanges == 14)
    }

    @Test func theIdentityReplyCarriesTheFirmwareVersion() throws {
        // Unacked, unlike every Arturia frame: measured, and what ends the exchange here.
        let answer = try hexBytes(identityReply)
        let wire = port { _ in [answer] }

        #expect(try DeviceTransport(port: wire, timeoutMs: 50).identify() == "2.5.20")
        #expect(wire.sent == [Sysex.identityRequest])
    }

    @Test func aMuteDeviceIsNotAnsweringRatherThanAbsent() throws {
        let device = DeviceTransport(port: port { _ in [] }, timeoutMs: 50)

        #expect(throws: DeviceError.notAnswering) { try device.identify() }
        #expect("\(DeviceError.notAnswering)".contains("killall MIDIServer"))
    }

    @Test func anUnreadableIdentityReplyShowsItsBytes() throws {
        let device = DeviceTransport(port: port { _ in [[0xF0, 0x7E, 0xF7]] }, timeoutMs: 50)

        let error = #expect(throws: DeviceError.self) { try device.identify() }
        #expect(error?.description.contains("f07ef7") == true)
    }

    @Test func theProloguePassesStraightThrough() throws {
        let wire = port { _ in [] }
        try DeviceTransport(port: wire, timeoutMs: 50).send(Sysex.prologue(4))

        #expect(wire.sent == [try Sysex.prologue(4)])
    }
}
