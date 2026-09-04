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

/// Where a three-index long reply's values start: header 6, command, slot, param, index count,
/// item, three indices, count. `src/ksp/sysex.py` parses the same offset as `12 + n_indices`.
let longReplyValues = 15

/// `01 <slot> 25 78` -- 120_37, the first read of MCC's own plan, and the frame `usb_probe scalar`
/// sends.
func scalarRequest(slot: UInt8) -> [UInt8] {
    header + [0x01, slot, 37, 120, end]
}

/// `0b <slot> 6d 03 7c 01 01 01 <count>` -- 124_109_1_1_1, the coalesced form. Its reply carries
/// `count` values, so it is the frame that says whether a long read survives the driver.
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

func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func bytes(fromHex text: some StringProtocol) -> [UInt8] {
    stride(from: 0, to: text.count - 1, by: 2).compactMap { offset in
        let start = text.index(text.startIndex, offsetBy: offset)
        let stop = text.index(start, offsetBy: 2)
        return UInt8(text[start..<stop], radix: 16)
    }
}

func describe(_ endpoint: MIDIEndpointRef) -> String {
    stringProperty(endpoint, kMIDIPropertyDisplayName)
}

/// A three-index read reply carrying `count` values.
func isFullReply(_ frame: [UInt8], count: Int) -> Bool {
    frame.count == longReplyValues + count + 1 && frame[6] == 0x0C && frame[14] == UInt8(count)
}

/// Whether a reply answers the address its request asked for. Everything between the command byte
/// and the terminator is echoed verbatim, short form and long form alike (spec 7.1).
func answers(_ reply: [UInt8], _ request: [UInt8]) -> Bool {
    let body = request.dropFirst(7).dropLast()
    guard reply.count >= 7 + body.count else { return false }
    return Array(reply[7..<(7 + body.count)]) == Array(body)
}

/// Whole SysEx messages off the input port, as a blocking queue.
///
/// `next` is the only way out, so the semaphore and the queue can never drift apart -- a drain that
/// bypassed the semaphore would leave stale signals that make a later wait return on an empty queue.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var frames: [(endpoint: String, bytes: [UInt8])] = []
    private let arrived = DispatchSemaphore(value: 0)

    func feed(_ endpoint: String, _ bytes: [UInt8]) {
        var completed = 0
        lock.lock()
        for byte in bytes {
            // Real-time bytes are legal *inside* a SysEx stream and the device emits clock whenever
            // its transport runs; appending one would corrupt the frame around it. `0xFF` is the
            // exception and must survive: System Reset never arrives mid-frame, and Arturia spends
            // that byte as the unset sentinel (spec 7.6). Dropping it loses 16 values a walk.
            if (0xF8...0xFE).contains(byte) { continue }
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

    func next(within seconds: Double) -> (endpoint: String, bytes: [UInt8])? {
        guard arrived.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return frames.isEmpty ? nil : frames.removeFirst()
    }
}

/// One client listening on every source, so a reply is caught whichever endpoint carries it.
final class Listener {
    let collector = Collector()
    let sources: [MIDIEndpointRef]
    let destinations: [MIDIEndpointRef]
    private var client = MIDIClientRef()
    private var input = MIDIPortRef()
    private var output = MIDIPortRef()

    init() throws {
        // Enumerated once: an index handed to the input block must not outlive the list it indexes,
        // and a device appearing mid-run would renumber a second enumeration.
        sources = (0..<MIDIGetNumberOfSources()).map(MIDIGetSource)
        destinations = (0..<MIDIGetNumberOfDestinations()).map(MIDIGetDestination)
        let names = sources.map(describe)

        try check(MIDIClientCreateWithBlock("ksp-probe" as CFString, &client, nil), "client")
        let collector = self.collector
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

        for (index, source) in sources.enumerated() {
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

    /// Everything that arrives within `seconds`, waiting on the device rather than spinning.
    func listen(seconds: Double) -> [(endpoint: String, bytes: [UInt8])] {
        var collected: [(endpoint: String, bytes: [UInt8])] = []
        let deadline = Date().addingTimeInterval(seconds)
        while let frame = collector.next(within: max(0, deadline.timeIntervalSinceNow)) {
            collected.append(frame)
        }
        return collected
    }

    /// One transaction: the request, then frames until the ack ends it (spec 7.1).
    func exchange(_ request: [UInt8], to destination: MIDIEndpointRef, wait: Double) throws
        -> [(endpoint: String, bytes: [UInt8])]
    {
        try send(request, to: destination)
        var collected: [(endpoint: String, bytes: [UInt8])] = []
        let deadline = Date().addingTimeInterval(wait)
        while let frame = collector.next(within: max(0, deadline.timeIntervalSinceNow)) {
            collected.append(frame)
            if frame.bytes == ack { break }
        }
        return collected
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

func destination(_ needle: String, _ listener: Listener) throws -> MIDIEndpointRef {
    guard
        let found = listener.destinations.first(where: {
            describe($0).localizedCaseInsensitiveContains(needle)
        })
    else { throw ProbeError("no destination matching \"\(needle)\"") }
    return found
}

// MARK: - probes

func listProbe() throws {
    let listener = try Listener()
    print("sources (\(listener.sources.count)):")
    for (index, endpoint) in listener.sources.enumerated() {
        print("  [\(index)] \(describe(endpoint))")
    }
    print("destinations (\(listener.destinations.count)):")
    for (index, endpoint) in listener.destinations.enumerated() {
        print("  [\(index)] \(describe(endpoint))")
    }
}

func exchangeProbe(needle: String, slot: UInt8, wait: Double) throws {
    let listener = try Listener()
    let target = try destination(needle, listener)
    print("destination \(describe(target)):")

    print("  identity request")
    report(identityRequest, try listener.exchange(identityRequest, to: target, wait: wait))

    print("  prologue then scalar read (slot \(slot))")
    try listener.send(prologue(slot: slot), to: target)
    _ = listener.listen(seconds: 0.2)
    let scalar = scalarRequest(slot: slot)
    report(scalar, try listener.exchange(scalar, to: target, wait: wait))

    for count in [16, 100] as [UInt8] {
        print("  coalesced read, count \(count) (slot \(slot))")
        let request = coalescedRequest(slot: slot, count: count)
        report(request, try listener.exchange(request, to: target, wait: wait))
    }
}

/// Reads 120_37 out of every slot, each behind its own prologue. Distinct pitch chunks are the
/// proof that slot selection survives the driver too, not just a single frame.
func slotsProbe(needle: String, wait: Double) throws {
    let listener = try Listener()
    let target = try destination(needle, listener)
    for slot in UInt8(1)...16 {
        try listener.send(prologue(slot: slot), to: target)
        _ = listener.listen(seconds: 0.2)

        let scalar = try listener.exchange(scalarRequest(slot: slot), to: target, wait: wait)
        guard let reply = scalar.first(where: { $0.bytes != ack }), reply.bytes.count == 12 else {
            print("  slot \(slot): no reply")
            continue
        }
        let chunk = try listener.exchange(
            coalescedRequest(slot: slot, count: 16), to: target, wait: wait)
        let values =
            chunk.first(where: { $0.bytes != ack })
            .map { hex($0.bytes.dropFirst(longReplyValues).prefix(8)) } ?? "none"
        print(
            "  slot \(slot): byte 7 = \(reply.bytes[7])  120_37 = \(reply.bytes[10])  "
                + "124_109_1_1_1 = \(values)")
    }
}

/// Sequential request/reply pairs, timed. 64 is what `bulk_fast` mostly issues; 100 is the ceiling.
func throughputProbe(needle: String, slot: UInt8, rounds: Int, wait: Double) throws {
    let listener = try Listener()
    let target = try destination(needle, listener)
    try listener.send(prologue(slot: slot), to: target)
    _ = listener.listen(seconds: 0.2)

    for count in [1, 16, 64, 100] as [UInt8] {
        let request = coalescedRequest(slot: slot, count: count)
        var answered = 0
        var acked = 0
        let started = Date()
        for _ in 0..<rounds {
            for frame in try listener.exchange(request, to: target, wait: wait) {
                if frame.bytes == ack {
                    acked += 1
                } else if isFullReply(frame.bytes, count: Int(count)) {
                    answered += 1
                }
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        print(
            "  count \(String(format: "%3d", Int(count))): \(answered)/\(rounds) replies, "
                + "\(acked) acks, \(String(format: "%.2f", elapsed))s "
                + "-- \(String(format: "%.2f", elapsed / Double(rounds) * 1000)) ms per exchange")
    }
}

/// Replays a real request plan -- one hex frame per line, as `ksp.bulk_fast` emits it -- and times
/// the whole walk. This is the only figure here that is a measured dump rather than a projection.
func replayProbe(needle: String, slot: UInt8, path: String, wait: Double) throws {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let plan = text.split(separator: "\n").map { bytes(fromHex: $0) }.filter { !$0.isEmpty }
    guard !plan.isEmpty else { throw ProbeError("no frames in \(path)") }

    let listener = try Listener()
    let target = try destination(needle, listener)
    try listener.send(prologue(slot: slot), to: target)
    _ = listener.listen(seconds: 0.2)

    var answered = 0
    var acked = 0
    var values = 0
    var mismatched = 0
    var silent: [String] = []
    var short: [String] = []
    let started = Date()
    for request in plan {
        for frame in try listener.exchange(request, to: target, wait: wait) {
            if frame.bytes == ack {
                acked += 1
            } else if answers(frame.bytes, request) {
                answered += 1
                let carried = frame.bytes.count - request.count
                values += carried
                let asked = request.count == 11 ? 1 : Int(request[request.count - 2])
                if carried != asked, short.count < 4 {
                    short.append(
                        "\(hex(request)) asked \(asked), got \(carried): \(hex(frame.bytes))")
                }
            } else {
                mismatched += 1
            }
        }
        if answered + mismatched < acked { silent.append(hex(request)) }
    }
    let elapsed = Date().timeIntervalSince(started)
    print("  plan            \(plan.count) requests from \(path)")
    print("  answered        \(answered)   acks \(acked)   mismatched \(mismatched)")
    print("  values returned \(values)")
    print(
        "  elapsed         \(String(format: "%.2f", elapsed))s "
            + "-- \(String(format: "%.2f", elapsed / Double(plan.count) * 1000)) ms per request")
    for line in short { print("  short reply     \(line)") }
    if !silent.isEmpty {
        print("  unanswered      \(silent.count), first \(silent.prefix(3).joined(separator: " "))")
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

func requestedSlot() throws -> UInt8 {
    guard arguments.count > 2 else { return 1 }
    // 0-127 is the codec's range (`sysex.MAX_SLOT`); a wider one must not trap the probe.
    guard let value = Int(arguments[2]), let slot = UInt8(exactly: value), slot <= 0x7F else {
        throw ProbeError("slot \"\(arguments[2])\" is not 0 to 127")
    }
    return slot
}

do {
    switch probe {
    case "list": try listProbe()
    case "exchange": try exchangeProbe(needle: needle, slot: try requestedSlot(), wait: 1.5)
    case "slots": try slotsProbe(needle: needle, wait: 1.5)
    case "throughput":
        try throughputProbe(needle: needle, slot: try requestedSlot(), rounds: 200, wait: 1.5)
    case "replay":
        guard arguments.count > 3 else { throw ProbeError("replay needs a plan file") }
        try replayProbe(
            needle: needle, slot: try requestedSlot(), path: arguments[3], wait: 1.5)
    case "sniff": try sniffProbe(seconds: Double(needle) ?? 20)
    default:
        print(
            "usage: coremidi_probe [list | exchange <name> <slot> | slots <name> "
                + "| throughput <name> <slot> | replay <name> <slot> <plan.txt> | sniff <seconds>]")
        exit(2)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
