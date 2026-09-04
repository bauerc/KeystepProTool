// Does the KeyStep Pro answer the SysEx read protocol over CoreMIDI? (issue #245)
//
// Standalone on purpose: it must not be a package target, because the answer decides whether a
// transport target is worth writing at all.
//
//   swiftc -O tools/coremidi_probe.swift -o /tmp/coremidi_probe && /tmp/coremidi_probe list

import CoreMIDI
import Foundation

let header: [UInt8] = [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42]
let end: UInt8 = 0xF7
let ack: [UInt8] = header + [0x1C, 0x00, end]
let identityRequest: [UInt8] = [0xF0, 0x7E, 0x7F, 0x06, 0x01, end]

/// `01 <slot> 25 78` -- 120_37, the first read of MCC's own plan, and the frame `usb_probe scalar`
/// sends. Eleven bytes: one CoreMIDI packet either way.
func scalarRequest(slot: UInt8) -> [UInt8] {
    header + [0x01, slot, 37, 120, end]
}

/// `0b <slot> 6d 03 7c 01 01 01 10` -- 124_109_1_1_1 count 16, the coalesced form. Its reply
/// carries sixteen values, so it is the frame that says whether a long read survives the driver.
func coalescedRequest(slot: UInt8, count: UInt8) -> [UInt8] {
    header + [0x0B, slot, 109, 0x03, 124, 1, 1, 1, count, end]
}

/// `05 <slot>` -- selects which project a read returns. Never answered.
func prologue(slot: UInt8) -> [UInt8] {
    header + [0x05, slot, end]
}

func stringProperty(_ object: MIDIObjectRef, _ property: CFString) -> String {
    var value: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(object, property, &value) == noErr, let value else {
        return "?"
    }
    return value.takeRetainedValue() as String
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func endpoints() -> ([MIDIEndpointRef], [MIDIEndpointRef]) {
    let sources = (0..<MIDIGetNumberOfSources()).map(MIDIGetSource)
    let destinations = (0..<MIDIGetNumberOfDestinations()).map(MIDIGetDestination)
    return (sources, destinations)
}

func describe(_ endpoint: MIDIEndpointRef) -> String {
    stringProperty(endpoint, kMIDIPropertyDisplayName)
}

/// Collects whole SysEx messages off one input port, reassembling across packets.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var frames: [(endpoint: String, bytes: [UInt8])] = []
    /// Signalled per completed frame, so a timing run waits on the device rather than on a poll.
    let arrived = DispatchSemaphore(value: 0)

    func feed(_ endpoint: String, _ bytes: [UInt8]) {
        lock.lock()
        var completed = 0
        for byte in bytes {
            if byte == 0xF0 {
                pending = [byte]
            } else if !pending.isEmpty {
                pending.append(byte)
                if byte == end {
                    frames.append((endpoint, pending))
                    pending = []
                    completed += 1
                }
            }
        }
        lock.unlock()
        for _ in 0..<completed { arrived.signal() }
    }

    func drain() -> [(endpoint: String, bytes: [UInt8])] {
        lock.lock()
        defer { lock.unlock() }
        let taken = frames
        frames = []
        return taken
    }
}

/// One client listening on every source, so a reply is caught whichever endpoint carries it.
final class Listener {
    let collector = Collector()
    private var client = MIDIClientRef()
    private var input = MIDIPortRef()
    private var output = MIDIPortRef()

    init() throws {
        try check(MIDIClientCreateWithBlock("ksp-probe" as CFString, &client, nil), "client")
        let collector = self.collector
        let names = endpoints().0.map(describe)
        try check(
            MIDIInputPortCreateWithBlock(client, "in" as CFString, &input) { packets, context in
                let index = context.map { $0.load(as: Int.self) } ?? -1
                let name = index >= 0 && index < names.count ? names[index] : "?"
                var packet = packets.pointee.packet
                for _ in 0..<packets.pointee.numPackets {
                    let bytes = withUnsafeBytes(of: packet.data) {
                        Array($0.prefix(Int(packet.length)))
                    }
                    collector.feed(name, bytes)
                    packet = MIDIPacketNext(&packet).pointee
                }
            }, "input port")
        try check(MIDIOutputPortCreate(client, "out" as CFString, &output), "output port")

        for (index, source) in endpoints().0.enumerated() {
            let box = UnsafeMutablePointer<Int>.allocate(capacity: 1)
            box.initialize(to: index)
            MIDIPortConnectSource(input, source, box)
        }
    }

    /// Every request this probe sends is at most sixteen bytes, so one stack `MIDIPacketList`
    /// holds it; a reply is what needs reassembling, not a request.
    func send(_ payload: [UInt8], to destination: MIDIEndpointRef) throws {
        var builder = MIDIPacketList()
        let packet = MIDIPacketListInit(&builder)
        MIDIPacketListAdd(
            &builder, MemoryLayout<MIDIPacketList>.size, packet, 0, payload.count, payload)
        try check(MIDISend(output, destination, &builder), "send")
    }

    /// Waits `seconds` for traffic, running the run loop so the input block fires.
    func listen(seconds: Double) -> [(endpoint: String, bytes: [UInt8])] {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return collector.drain()
    }
}

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw ProbeError("\(what) failed: OSStatus \(status)") }
}

func report(_ request: [UInt8], _ replies: [(endpoint: String, bytes: [UInt8])]) {
    print("    sent  \(hex(request))")
    if replies.isEmpty {
        print("    reply NONE")
        return
    }
    for reply in replies {
        let note = reply.bytes == ack ? "  (ack)" : ""
        print("    reply \(hex(reply.bytes))  <- \(reply.endpoint)\(note)")
    }
}

func matching(_ needle: String, _ list: [MIDIEndpointRef]) -> [MIDIEndpointRef] {
    list.filter { describe($0).localizedCaseInsensitiveContains(needle) }
}

// MARK: - probes

func listProbe() {
    let (sources, destinations) = endpoints()
    print("sources (\(sources.count)):")
    for (index, endpoint) in sources.enumerated() { print("  [\(index)] \(describe(endpoint))") }
    print("destinations (\(destinations.count)):")
    for (index, endpoint) in destinations.enumerated() {
        print("  [\(index)] \(describe(endpoint))")
    }
}

func exchangeProbe(needle: String, slot: UInt8, wait: Double) throws {
    let listener = try Listener()
    let targets = matching(needle, endpoints().1)
    guard !targets.isEmpty else { throw ProbeError("no destination matching \"\(needle)\"") }

    for destination in targets {
        print("destination \(describe(destination)):")

        print("  identity request")
        _ = listener.listen(seconds: 0.1)
        try listener.send(identityRequest, to: destination)
        report(identityRequest, listener.listen(seconds: wait))

        print("  prologue then scalar read (slot \(slot))")
        try listener.send(prologue(slot: slot), to: destination)
        _ = listener.listen(seconds: 0.2)
        let scalar = scalarRequest(slot: slot)
        try listener.send(scalar, to: destination)
        report(scalar, listener.listen(seconds: wait))

        print("  coalesced read, count 16 (slot \(slot))")
        let coalesced = coalescedRequest(slot: slot, count: 16)
        try listener.send(coalesced, to: destination)
        report(coalesced, listener.listen(seconds: wait))

        print("  coalesced read, count 100 (slot \(slot))")
        let long = coalescedRequest(slot: slot, count: 100)
        try listener.send(long, to: destination)
        report(long, listener.listen(seconds: wait))
    }
}

/// Reads 120_37 out of every slot, each behind its own prologue. Distinct values are the proof
/// that slot selection survives the driver too, not just a single frame.
func slotsProbe(needle: String, wait: Double) throws {
    let listener = try Listener()
    guard let destination = matching(needle, endpoints().1).first else {
        throw ProbeError("no destination matching \"\(needle)\"")
    }
    for slot in UInt8(1)...16 {
        try listener.send(prologue(slot: slot), to: destination)
        _ = listener.listen(seconds: 0.2)
        let request = scalarRequest(slot: slot)
        try listener.send(request, to: destination)
        let replies = listener.listen(seconds: wait).filter { $0.bytes != ack }
        guard let reply = replies.first, reply.bytes.count == 12 else {
            print("  slot \(slot): no reply")
            continue
        }
        let chunk = coalescedRequest(slot: slot, count: 16)
        try listener.send(chunk, to: destination)
        let pitches = listener.listen(seconds: wait).filter { $0.bytes != ack }
        let head = pitches.first.map { hex(Array($0.bytes.dropFirst(12).prefix(8))) } ?? "none"
        print(
            "  slot \(slot): byte 7 = \(reply.bytes[7])  120_37 = \(reply.bytes[10])  "
                + "124_109_1_1_1 = \(head)")
    }
}

/// A three-index read reply carrying `count` values: header 6, command, slot, param, index count,
/// item, three indices, count -- fifteen bytes -- then the values and `F7`.
func isFullReply(_ frame: [UInt8], count: Int) -> Bool {
    frame.count == 16 + count && frame.dropFirst(6).first == 0x0C && frame[14] == UInt8(count)
}

/// Sequential request/reply pairs, timed. The whole-project read is thousands of these, so the
/// per-exchange cost is what decides whether a CoreMIDI read is usable at all.
func throughputProbe(needle: String, slot: UInt8, rounds: Int, wait: Double) throws {
    let listener = try Listener()
    guard let destination = matching(needle, endpoints().1).first else {
        throw ProbeError("no destination matching \"\(needle)\"")
    }
    try listener.send(prologue(slot: slot), to: destination)
    _ = listener.listen(seconds: 0.2)

    // 64 is what bulk_fast actually issues -- the 64-step items bind long before the 100 of 7.7.
    for count in [1, 16, 64, 100] as [UInt8] {
        let request = coalescedRequest(slot: slot, count: count)
        var answered = 0
        var acked = 0
        let started = Date()
        for _ in 0..<rounds {
            try listener.send(request, to: destination)
            // Request, reply, ack -- strictly serialised, so two frames end the transaction.
            var sawReply = false
            for _ in 0..<2 {
                guard listener.collector.arrived.wait(timeout: .now() + wait) == .success else {
                    break
                }
                for frame in listener.collector.drain() {
                    if frame.bytes == ack {
                        acked += 1
                    } else if isFullReply(frame.bytes, count: Int(count)) {
                        sawReply = true
                    }
                }
            }
            if sawReply { answered += 1 }
        }
        let elapsed = Date().timeIntervalSince(started)
        print(
            "  count \(String(format: "%3d", Int(count))): \(answered)/\(rounds) replies, "
                + "\(acked) acks, \(String(format: "%.2f", elapsed))s "
                + "-- \(String(format: "%.2f", elapsed / Double(rounds) * 1000)) ms per exchange")
    }
}

/// Sends nothing; just prints whatever arrives. Run it while MCC does a Recall From.
func sniffProbe(seconds: Double) throws {
    let listener = try Listener()
    print("listening \(seconds)s on every source...")
    for frame in listener.listen(seconds: seconds) {
        print("  \(hex(frame.bytes))  <- \(frame.endpoint)")
    }
}

// MARK: - main

let arguments = Array(CommandLine.arguments.dropFirst())
let probe = arguments.first ?? "list"
let needle = arguments.count > 1 ? arguments[1] : "KeyStep Pro"
let slot = UInt8(arguments.count > 2 ? Int(arguments[2]) ?? 1 : 1)

do {
    switch probe {
    case "list": listProbe()
    case "exchange": try exchangeProbe(needle: needle, slot: slot, wait: 1.5)
    case "slots": try slotsProbe(needle: needle, wait: 1.5)
    case "throughput": try throughputProbe(needle: needle, slot: slot, rounds: 200, wait: 1.5)
    case "sniff": try sniffProbe(seconds: Double(needle) ?? 20)
    default:
        print(
            "usage: coremidi_probe "
                + "[list | exchange <name> <slot> | slots <name> | throughput <name> <slot> "
                + "| sniff <seconds>]")
        exit(2)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
