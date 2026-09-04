import CoreMIDI
import Foundation

/// The device's CoreMIDI endpoint pair. No privilege, no interface claim and no vendor id:
/// the endpoint is found by name, and talking through `MIDIServer` reaches the same interface
/// the raw path would have evicted it from (spec 7.9).
final class CoreMIDIPort: SysExPort {
    /// A `MIDIPacket`'s inline data buffer.
    private let packetCapacity = MemoryLayout.size(ofValue: MIDIPacket().data)

    private let frames = FrameQueue()
    private var client = MIDIClientRef()
    private var input = MIDIPortRef()
    private var output = MIDIPortRef()
    private var destination = MIDIEndpointRef()

    /// One input port, connected to the device's own source alone -- a Mac with other MIDI gear
    /// attached would otherwise queue that gear's traffic as our replies.
    init(named needle: String) throws {
        let matches = { (endpoint: MIDIEndpointRef) in
            displayName(endpoint).localizedCaseInsensitiveContains(needle)
        }
        let sources = (0..<MIDIGetNumberOfSources()).map(MIDIGetSource).filter(matches)
        guard
            let found = (0..<MIDIGetNumberOfDestinations()).map(MIDIGetDestination).first(
                where: matches),
            !sources.isEmpty
        else { throw DeviceError.notAttached(needle) }
        destination = found

        try check(
            MIDIClientCreateWithBlock("ksp" as CFString, &client, nil), "creating the MIDI client")
        let frames = self.frames
        try check(
            MIDIInputPortCreateWithBlock(client, "ksp-in" as CFString, &input) { packets, _ in
                var packet = packets.pointee.packet
                for _ in 0..<packets.pointee.numPackets {
                    frames.feed(
                        withUnsafeBytes(of: packet.data) { Array($0.prefix(Int(packet.length))) })
                    packet = MIDIPacketNext(&packet).pointee
                }
            }, "opening the input port")
        try check(
            MIDIOutputPortCreate(client, "ksp-out" as CFString, &output), "opening the output port")
        for source in sources {
            try check(
                MIDIPortConnectSource(input, source, nil),
                "listening to \(displayName(source))")
        }
    }

    deinit {
        MIDIClientDispose(client)
    }

    /// Every frame this sends is a request, and the longest is sixteen bytes, so one stack
    /// `MIDIPacketList` holds it whole. `MIDIPacketListAdd` answers a silent NULL on overflow.
    func send(_ frame: [UInt8]) throws {
        guard frame.count <= packetCapacity else {
            throw DeviceError.confused(
                "\(frame.count) bytes is more than the \(packetCapacity) one MIDI packet carries")
        }
        var list = MIDIPacketList()
        let packet = MIDIPacketListInit(&list)
        MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, packet, 0, frame.count, frame)
        try check(MIDISend(output, destination, &list), "sending \(hex(frame))")
    }

    func nextFrame(within seconds: Double) -> [UInt8]? {
        frames.next(within: seconds)
    }
}

private func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw DeviceError.coreMIDI(what, status) }
}

private func displayName(_ endpoint: MIDIEndpointRef) -> String {
    var value: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value) == noErr,
        let value
    else { return "" }
    return value.takeRetainedValue() as String
}
