import CoreMIDI
import Foundation

/// The device's CoreMIDI endpoint pair, found by name. No privilege, no interface claim and no
/// vendor id: `MIDIServer` reaches the interface the raw path would have evicted it from (7.9).
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
                where: matches)
        else { throw DeviceError.notAttached(needle) }
        // Half a pair: sends would land and nothing could come back, so it is the mute
        // endpoint of 7.9.2 rather than an absent device, and takes that advice.
        guard !sources.isEmpty else { throw DeviceError.notAnswering }
        destination = found

        try check(
            MIDIClientCreateWithBlock("ksp" as CFString, &client, nil), "creating the MIDI client")
        let queue = frames
        try check(
            MIDIInputPortCreateWithBlock(client, "ksp-in" as CFString, &input) { packets, _ in
                for frame in packetFrames(in: packets) { queue.feed(frame) }
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
    /// `MIDIPacketList` holds it whole -- and `MIDIPacketListAdd` overflows to a silent NULL.
    func send(_ frame: [UInt8]) throws {
        guard frame.count <= packetCapacity else {
            throw DeviceError.oversizedFrame(frame.count, capacity: packetCapacity)
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

/// Every packet one callback was handed. The list's own iterator, never `MIDIPacketNext` over a
/// copied packet: that copy is 268 bytes read out of a smaller buffer, and stepping from it
/// addresses the copy's own storage rather than the next packet.
func packetFrames(in packets: UnsafePointer<MIDIPacketList>) -> [[UInt8]] {
    packets.unsafeSequence().map { Array($0.bytes()) }
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
