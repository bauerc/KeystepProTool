import CoreMIDI
import Testing

@testable import KSPDevice

@Suite struct CoreMIDIPortTests {
    @Test func anAbsentDeviceFailsBeforeAnythingIsOpened() {
        let missing = "KeyStep Pro (no such endpoint)"

        #expect(throws: DeviceError.notAttached(missing)) { try CoreMIDIPort(named: missing) }
    }

    /// A reply and the ack that closes it arrive in one callback, and a long reply arrives split.
    @Test func everyPacketOfOneCallbackIsRead() throws {
        let frames: [[UInt8]] = [
            [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42, 0x0C, 0x3C, 0xF7],
            [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42, 0x1C, 0xF7],
            [0xF0, 0x7E, 0x7F, 0x06, 0x02, 0xF7],
        ]
        var list = MIDIPacketList()
        var packet = MIDIPacketListInit(&list)
        for frame in frames {
            packet = MIDIPacketListAdd(
                &list, MemoryLayout<MIDIPacketList>.size, packet, 0, frame.count, frame)
        }

        #expect(withUnsafePointer(to: &list) { packetFrames(in: $0) } == frames)
    }

    @Test func theMessageNamesTheFix() {
        let error = DeviceError.notAttached(KeyStepPro.endpointName)

        #expect(error.description.contains("KeyStep Pro"))
        #expect(error.description.contains("plugged in over USB and powered on"))
    }
}
