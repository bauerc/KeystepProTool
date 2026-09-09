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

/// One item, `window` consecutive third indices -- what a coalesced walk actually issues.
func steps(_ window: Int, slot: UInt8, item: UInt8 = 124) -> [[UInt8]] {
    (0..<window).map { header + [0x0B, slot, 109, 0x03, item, 1, 1, UInt8(1 + $0), 16, end] }
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

/// A frame and when it landed. `at` is taken in the MIDI callback rather than after the
/// semaphore wakes, so a waiter's scheduling delay is not billed to the device; `stamped` is the
/// driver's own timestamp for the same packet, and is 0 where the source does not set one.
struct Frame {
    let endpoint: String
    let bytes: [UInt8]
    let at: UInt64
    let stamped: UInt64
}

/// Mach's absolute time unit is not a nanosecond on every machine, and `DispatchTime` counts in
/// the converted one -- so a raw `MIDIPacket.timeStamp` has to be scaled before the two compare.
func nanos(fromHostTime ticks: UInt64) -> UInt64 {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return ticks * UInt64(info.numer) / UInt64(info.denom)
}

/// Whole SysEx messages off the input port, as a blocking queue.
///
/// `next` is the only way out, so the semaphore and the queue can never drift apart -- a drain that
/// bypassed the semaphore would leave stale signals that make a later wait return on an empty queue.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var frames: [Frame] = []
    private let arrived = DispatchSemaphore(value: 0)

    func feed(_ endpoint: String, _ bytes: [UInt8], at arrival: UInt64, stamped: UInt64) {
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
                    frames.append(
                        Frame(endpoint: endpoint, bytes: pending, at: arrival, stamped: stamped))
                    pending = []
                    completed += 1
                }
            }
        }
        lock.unlock()
        for _ in 0..<completed { arrived.signal() }
    }

    /// Whatever a previous block left queued, so its acks are not billed to the next one.
    func drain() {
        while next(within: 0) != nil {}
    }

    func next(within seconds: Double) -> Frame? {
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
                let arrival = DispatchTime.now().uptimeNanoseconds
                for packet in packets.unsafeSequence() {
                    collector.feed(
                        name, Array(packet.bytes()), at: arrival,
                        stamped: nanos(fromHostTime: packet.pointee.timeStamp))
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
    func listen(seconds: Double) -> [Frame] {
        var collected: [Frame] = []
        let deadline = Date().addingTimeInterval(seconds)
        while let frame = collector.next(within: max(0, deadline.timeIntervalSinceNow)) {
            collected.append(frame)
        }
        return collected
    }

    /// One transaction: the request, then frames until the ack ends it (spec 7.1).
    func exchange(_ request: [UInt8], to destination: MIDIEndpointRef, wait: Double) throws
        -> [Frame]
    {
        try send(request, to: destination)
        var collected: [Frame] = []
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

func report(_ request: [UInt8], _ replies: [Frame]) {
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
    var echoed: [(request: [UInt8], reply: [UInt8])] = []
    var short: [String] = []
    let started = Date()
    for request in plan {
        for frame in try listener.exchange(request, to: target, wait: wait) {
            if frame.bytes == ack {
                acked += 1
            } else if answers(frame.bytes, request) {
                answered += 1
                if plan.count <= 32 {
                    echoed.append((request, Array(frame.bytes.dropFirst(request.count - 1).dropLast())))
                }
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
    if plan.count <= 32 {
        for (request, reply) in echoed {
            print("  \(hex(request)) -> values \(hex(reply))")
        }
    }
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

/// Milliseconds between two callback stamps, signed: an ack that beat its reply must read
/// negative rather than wrap.
func ms(_ from: UInt64, _ to: UInt64) -> Double {
    (Double(to) - Double(from)) / 1_000_000
}

func mean(_ samples: [Double]) -> Double {
    samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
}

func spread(_ label: String, _ samples: [Double]) -> String {
    guard !samples.isEmpty else { return "    \(label) none" }
    let sorted = samples.sorted()
    let at = { (fraction: Double) in
        sorted[min(sorted.count - 1, Int(fraction * Double(sorted.count)))]
    }
    let figures = [sorted[0], at(0.5), mean(samples), at(0.95), sorted[sorted.count - 1]]
        .map { String(format: "%6.3f", $0) }.joined(separator: "  ")
    return "    \(label)  \(figures)"
}

/// Where an exchange's 4 ms goes: request out, reply in, ack in. Every figure the project has
/// measures `exchange()` whole, which blocks until the ack -- so whether the ack is worth waiting
/// for has never been answered.
///
/// The last block drops the ack wait outright, dispatching the next request on the reply. That is
/// the one-line change the decomposition either justifies or rules out.
func cadenceProbe(needle: String, slot: UInt8, rounds: Int, wait: Double) throws {
    let listener = try Listener()
    let target = try destination(needle, listener)
    let name = describe(target)
    try listener.send(prologue(slot: slot), to: target)
    _ = listener.listen(seconds: 0.2)

    print("  \(rounds) rounds per count, slot \(slot), arrival stamped in the MIDI callback")
    print("                            min     med    mean     p95     max   (ms)")
    for count in [1, 16, 64, 100] as [UInt8] {
        let request = coalescedRequest(slot: slot, count: count)
        var toReply: [Double] = []
        var replyToAck: [Double] = []
        var ackToSend: [Double] = []
        var lag: [Double] = []
        var ackFirst = 0
        var incomplete = 0
        var previousAck: UInt64 = 0
        let started = Date()

        // Round zero warms the path -- the first exchange of a count pays for whatever the driver
        // sets up once -- and only seeds the ack the second round measures its turnaround from.
        for round in 0...rounds {
            let sent = DispatchTime.now().uptimeNanoseconds
            try listener.send(request, to: target)
            var reply: Frame?
            var acked: Frame?
            let deadline = Date().addingTimeInterval(wait)
            while acked == nil,
                let frame = listener.collector.next(within: max(0, deadline.timeIntervalSinceNow))
            {
                guard frame.endpoint == name else { continue }
                if frame.bytes == ack { acked = frame } else { reply = frame }
            }
            guard let acked else { incomplete += 1; continue }
            guard round > 0 else { previousAck = acked.at; continue }
            guard let reply else { incomplete += 1; previousAck = acked.at; continue }
            if reply.at > acked.at { ackFirst += 1 }
            toReply.append(ms(sent, reply.at))
            replyToAck.append(ms(reply.at, acked.at))
            ackToSend.append(ms(previousAck, sent))
            if reply.stamped != 0 { lag.append(ms(reply.stamped, reply.at)) }
            previousAck = acked.at
        }

        let each = Date().timeIntervalSince(started) / Double(rounds + 1) * 1000
        print("  count \(String(format: "%3d", Int(count))):")
        print(spread("send  -> reply", toReply))
        print(spread("reply -> ack  ", replyToAck))
        print(spread("ack   -> send ", ackToSend))
        print(spread("driver -> call", lag))
        print(
            "    whole exchange \(String(format: "%.2f", each)) ms"
                + "  -- \(incomplete) incomplete, \(ackFirst) ack before reply")
    }

    // The ack wait, dropped: the next request goes out on the reply, and whatever acks the device
    // sends are consumed wherever they land. A reply that stops echoing its own address is the
    // failure this is watching for.
    print("  ack wait dropped -- next request dispatched on the reply:")
    for count in [1, 64] as [UInt8] {
        let request = coalescedRequest(slot: slot, count: count)
        listener.collector.drain()
        var answered = 0
        var acks = 0
        var mismatched = 0
        var silent = 0
        let started = Date()
        for _ in 0..<rounds {
            try listener.send(request, to: target)
            var got = false
            let deadline = Date().addingTimeInterval(wait)
            while !got,
                let frame = listener.collector.next(within: max(0, deadline.timeIntervalSinceNow))
            {
                guard frame.endpoint == name else { continue }
                if frame.bytes == ack {
                    acks += 1
                } else if answers(frame.bytes, request) {
                    answered += 1
                    got = true
                } else {
                    mismatched += 1
                    got = true
                }
            }
            if !got { silent += 1 }
        }
        let each = Date().timeIntervalSince(started) / Double(rounds) * 1000
        acks += listener.listen(seconds: 0.3).filter { $0.bytes == ack }.count
        print(
            "  count \(String(format: "%3d", Int(count))): "
                + "\(String(format: "%.2f", each)) ms per exchange  -- \(answered)/\(rounds) "
                + "echoed, \(acks) acks, \(mismatched) misaddressed, \(silent) silent")
    }
}

/// Is the 4 ms a latency or a service rate? `cadence` shows a reply does not come sooner for being
/// asked sooner, which a decomposition alone cannot tell from a fixed round trip. So this sends a
/// whole window unanswered and times what comes back.
///
/// Each request in a window addresses a different index, so a reply is matched by the address it
/// echoes rather than by its position -- the failure that let #255 hide. Throughput is averaged
/// over loss-free rounds alone: a window that dropped half its requests answers its survivors
/// quickly, and reading that as a speed-up is exactly the mistake to avoid.
func burst(
    _ listener: Listener, to target: MIDIEndpointRef, named name: String, label: String,
    requests: [[UInt8]], pace: Double, rounds: Int, wait: Double
) throws {
    let window = requests.count
    var whole: [Double] = []
    var first: [Double] = []
    var gaps: [Double] = []
    var every: [Double] = []
    var lost = 0
    var unmatched = 0
    var complete = 0

    for round in 0...rounds {
        listener.collector.drain()
        var outstanding = Set(requests.map(hex))
        let sent = DispatchTime.now().uptimeNanoseconds
        for (index, request) in requests.enumerated() {
            if pace > 0, index > 0 { Thread.sleep(forTimeInterval: pace) }
            try listener.send(request, to: target)
        }
        var arrivals: [UInt64] = []
        let deadline = Date().addingTimeInterval(wait)
        while !outstanding.isEmpty,
            let frame = listener.collector.next(
                within: min(0.05, max(0, deadline.timeIntervalSinceNow)))
        {
            guard frame.endpoint == name, frame.bytes != ack else { continue }
            guard let match = requests.first(where: { answers(frame.bytes, $0) }),
                outstanding.remove(hex(match)) != nil
            else {
                if round > 0 { unmatched += 1 }
                continue
            }
            arrivals.append(frame.at)
        }
        guard round > 0 else { continue }
        lost += outstanding.count
        guard outstanding.isEmpty, let opened = arrivals.first, let closed = arrivals.last else {
            continue
        }
        complete += 1
        whole.append(ms(sent, closed))
        first.append(ms(sent, opened))
        if window > 1 {
            gaps.append(ms(opened, closed) / Double(window - 1))
            for (earlier, later) in zip(arrivals, arrivals.dropFirst()) {
                every.append(ms(earlier, later))
            }
        }
    }

    let paced = pace > 0 ? String(format: " paced %.0f\u{00B5}s", pace * 1_000_000) : "          "
    print(
        "  \(label)\(paced): "
            + "first reply \(String(format: "%6.3f", mean(first))) ms, "
            + "gap \(String(format: "%6.3f", mean(gaps))) ms, "
            + "window \(String(format: "%7.3f", mean(whole))) ms "
            + "-> \(String(format: "%5.3f", mean(whole) / Double(window))) ms per reply  "
            + "-- \(complete)/\(rounds) rounds whole, \(lost) lost, \(unmatched) unmatched")
    // The mean hides the shape. A device on a 2 ms grid spending two slots per read gives one
    // 4 ms bar; anything landing on 2 ms is a slot the ack did not take.
    if !every.isEmpty {
        let tally = Dictionary(grouping: every) { ($0 * 2).rounded() / 2 }
            .mapValues(\.count).sorted { $0.key < $1.key }
        print(
            "               gaps: "
                + tally.map { "\(String(format: "%.1f", $0.key))ms x\($0.value)" }
                .joined(separator: "  "))
    }
}

func pipelineProbe(needle: String, slot: UInt8, rounds: Int, wait: Double) throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let listener = try Listener()
    let target = try destination(needle, listener)
    let name = describe(target)
    try listener.send(prologue(slot: slot), to: target)
    _ = listener.listen(seconds: 0.2)

    print("  \(rounds) rounds per window, slot \(slot); throughput over loss-free rounds only")
    for window in [1, 2, 3, 4, 8] {
        try burst(
            listener, to: target, named: name, label: "window \(String(format: "%2d", window))",
            requests: steps(window, slot: slot), pace: 0, rounds: rounds, wait: wait)
    }
    print("  the same windows, sends spread out -- is the ceiling a buffer or a parse rate?")
    for (window, pace) in [
        (4, 0.001), (4, 0.002), (8, 0.002), (8, 0.004), (16, 0.002), (16, 0.0025), (16, 0.003),
        (32, 0.002), (64, 0.002),
    ] {
        try burst(
            listener, to: target, named: name, label: "window \(String(format: "%2d", window))",
            requests: steps(window, slot: slot), pace: pace, rounds: rounds, wait: wait)
    }

    // The last way the rate could be beaten: if 4 ms were a per-item lock rather than the
    // device's own service tick, two items in flight would answer in parallel.
    print("  across items, and across parameters -- is the tick per item or per device?")
    try burst(
        listener, to: target, named: name, label: "2 items   ",
        requests: [steps(1, slot: slot, item: 124)[0], steps(1, slot: slot, item: 125)[0]],
        pace: 0, rounds: rounds,
        wait: wait)
    try burst(
        listener, to: target, named: name, label: "4 items   ",
        requests: [123, 124, 125, 126].map { steps(1, slot: slot, item: UInt8($0))[0] }, pace: 0,
        rounds: rounds, wait: wait)
    try burst(
        listener, to: target, named: name, label: "4 items p ",
        requests: [123, 124, 125, 126].map { steps(1, slot: slot, item: UInt8($0))[0] }, pace: 0.002,
        rounds: rounds, wait: wait)
    // A short scalar read (`01`) beside the long one (`0b`): a different command, same question.
    try burst(
        listener, to: target, named: name, label: "scalar x1 ",
        requests: [scalarRequest(slot: slot)], pace: 0, rounds: rounds, wait: wait)
    try burst(
        listener, to: target, named: name, label: "scalar x2 ",
        requests: [scalarRequest(slot: slot), header + [0x01, slot, 38, 120, end]],
        pace: 0, rounds: rounds, wait: wait)
}

/// Latency or tick? The two models fit `cadence` equally well, and they disagree about what a
/// transport rewrite is worth, so this separates them: hold off `delay` ms after each reply before
/// asking again, and watch the reply-to-reply period.
///
///   fixed latency L, free to answer whenever asked -> period tracks the delay, `delay + L`
///   a service tick the device answers on          -> period stays pinned, whatever the delay
///
/// Sub-millisecond spacing is the whole point, so the wait spins rather than sleeping: `Thread`
/// rounds to something coarser than the effect being measured.
func gridProbe(needle: String, slot: UInt8, rounds: Int, wait: Double) throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let listener = try Listener()
    let target = try destination(needle, listener)
    let name = describe(target)
    try listener.send(prologue(slot: slot), to: target)
    _ = listener.listen(seconds: 0.2)
    let request = coalescedRequest(slot: slot, count: 16)

    print("  \(rounds) rounds per delay, slot \(slot); delay measured from the previous reply")
    print("  delay     send -> reply        reply -> reply")
    for delay in [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 5.0, 6.0] {
        var latency: [Double] = []
        var period: [Double] = []
        var previous: UInt64 = 0
        for round in 0...rounds {
            if previous != 0, delay > 0 {
                let until = previous + UInt64(delay * 1_000_000)
                while DispatchTime.now().uptimeNanoseconds < until {}
            }
            let sent = DispatchTime.now().uptimeNanoseconds
            try listener.send(request, to: target)
            var reply: Frame?
            let deadline = Date().addingTimeInterval(wait)
            while reply == nil,
                let frame = listener.collector.next(within: max(0, deadline.timeIntervalSinceNow))
            {
                guard frame.endpoint == name, frame.bytes != ack, answers(frame.bytes, request)
                else { continue }
                reply = frame
            }
            guard let reply else { continue }
            if round > 0, previous != 0 {
                latency.append(ms(sent, reply.at))
                period.append(ms(previous, reply.at))
            }
            previous = reply.at
        }
        let range = { (samples: [Double]) in
            samples.isEmpty
                ? "     -" : String(format: "%6.3f-%6.3f", samples.min()!, samples.max()!)
        }
        print(
            "  \(String(format: "%4.1f", delay)) ms  "
                + "\(String(format: "%6.3f", mean(latency))) [\(range(latency))]  "
                + "\(String(format: "%6.3f", mean(period))) [\(range(period))]")
    }

    // Periods that step 4, 6, 8 put replies on a 2 ms grid, and a read spends two slots of it.
    // The identity reply is the one frame the device does not ack (spec 7.1), so if the second
    // slot is the ack, an unacked exchange must come back on half the period.
    var period: [Double] = []
    var previous: UInt64 = 0
    for round in 0...rounds {
        try listener.send(identityRequest, to: target)
        var reply: Frame?
        let deadline = Date().addingTimeInterval(wait)
        while reply == nil,
            let frame = listener.collector.next(within: max(0, deadline.timeIntervalSinceNow))
        {
            guard frame.endpoint == name, frame.bytes.starts(with: [0xF0, 0x7E]) else { continue }
            reply = frame
        }
        guard let reply else { continue }
        if round > 0, previous != 0 { period.append(ms(previous, reply.at)) }
        previous = reply.at
    }
    print(
        "  identity (never acked), delay 0.0 ms: reply -> reply "
            + "\(String(format: "%6.3f", mean(period))) ms "
            + "[\(String(format: "%6.3f-%6.3f", period.min() ?? 0, period.max() ?? 0))]")
}

/// A real plan walked with a window of requests in flight, paced so the device's intake keeps up.
/// The synthetic bursts say ~3 ms a reply is reachable; this is the same claim against the request
/// stream a pull actually issues, which mixes short and long forms and every item.
///
/// A reply is claimed by the request whose address it echoes, never by arrival order.
func pipeReplayProbe(
    needle: String, slot: UInt8, path: String, window: Int, pace: Double, wait: Double
) throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let plan = text.split(separator: "\n").map { bytes(fromHex: $0) }.filter { !$0.isEmpty }
    guard !plan.isEmpty else { throw ProbeError("no frames in \(path)") }

    let listener = try Listener()
    let target = try destination(needle, listener)
    let name = describe(target)
    try listener.send(prologue(slot: slot), to: target)
    _ = listener.listen(seconds: 0.2)

    // A short read is answered by `02` and a long one by `0c`, so the command byte joins the
    // echoed address in claiming a reply -- the two body shapes are otherwise free to collide.
    func claims(_ reply: [UInt8], _ request: [UInt8]) -> Bool {
        guard reply.count > 6, request.count > 6 else { return false }
        let expected: UInt8 = request[6] == 0x01 ? 0x02 : 0x0C
        return reply[6] == expected && answers(reply, request)
    }

    var inFlight: [[UInt8]] = []
    var next = 0
    var answered = 0
    var lost = 0
    var unmatched = 0
    var values = 0
    var lastSend: UInt64 = 0
    var retried = 0
    var attempts = 0
    let started = Date()

    while answered + lost < plan.count {
        while inFlight.count < window, next < plan.count {
            if pace > 0, lastSend != 0 {
                let until = lastSend + UInt64(pace * 1_000_000)
                while DispatchTime.now().uptimeNanoseconds < until {}
            }
            try listener.send(plan[next], to: target)
            lastSend = DispatchTime.now().uptimeNanoseconds
            inFlight.append(plan[next])
            next += 1
        }
        guard let frame = listener.collector.next(within: wait) else {
            // Silence for a whole timeout means the device dropped what is still outstanding.
            // A walk that skipped those would write defaults over real values, so they are asked
            // again -- and the retry is part of what pipelining costs.
            guard attempts < 8 else {
                lost += inFlight.count
                inFlight.removeAll()
                continue
            }
            attempts += 1
            retried += inFlight.count
            for request in inFlight { try listener.send(request, to: target) }
            continue
        }
        guard frame.endpoint == name, frame.bytes != ack else { continue }
        guard let hit = inFlight.firstIndex(where: { claims(frame.bytes, $0) }) else {
            unmatched += 1
            continue
        }
        values += frame.bytes.count - inFlight[hit].count
        inFlight.remove(at: hit)
        answered += 1
    }

    let elapsed = Date().timeIntervalSince(started)
    print(
        "  window \(window), pace \(String(format: "%.1f", pace * 1000)) ms: "
            + "\(String(format: "%.2f", elapsed))s for \(plan.count) requests "
            + "-- \(String(format: "%.3f", elapsed / Double(plan.count) * 1000)) ms each, "
            + "\(answered) answered, \(retried) re-asked, \(lost) lost, "
            + "\(unmatched) unmatched, \(values) values")
}

/// Can the device be *told* not to ack, or told how deep a burst to take? The ack costs a 2 ms
/// transmit slot -- half of every read -- so a flag that suppresses it would be worth more than
/// every request the walk could prune.
///
/// The write direction is the precedent: it takes a whole burst unbuffered and answers it with one
/// ack at the `06` commit, so the ack regime is already something the session framing selects.
/// This asks whether the read direction has the same switch.
///
/// Every frame here is a known read opcode (`01`, `0b`, `05`) with its own fields varied. Inventing
/// command bytes is what is deliberately not done: `02`, `06` and `0c` are the write opcodes, there
/// is no restore path in this tool, and an unknown opcode carrying a slot byte could commit
/// something no probe can undo.
func handshakeProbe(needle: String, slot: UInt8) throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let listener = try Listener()
    let target = try destination(needle, listener)
    let name = describe(target)

    /// Sends one frame and reports what came back, without assuming either arrives.
    func probe(_ frame: [UInt8], settle: Double = 0.06) throws -> (
        reply: [UInt8]?, ack: Bool, extra: Int
    ) {
        listener.collector.drain()
        try listener.send(frame, to: target)
        var reply: [UInt8]?
        var acked = false
        var extra = 0
        let deadline = Date().addingTimeInterval(settle)
        while let got = listener.collector.next(
            within: max(0, deadline.timeIntervalSinceNow))
        {
            guard got.endpoint == name else { continue }
            if got.bytes == ack {
                acked = true
            } else if reply == nil {
                reply = got.bytes
            } else {
                extra += 1
            }
        }
        return (reply, acked, extra)
    }

    func sign(_ result: (reply: [UInt8]?, ack: Bool, extra: Int)) -> String {
        let body = result.reply.map { "reply \($0.count)b" } ?? "SILENT"
        return "\(body), \(result.ack ? "acked" : "NO ACK")"
            + (result.extra > 0 ? ", +\(result.extra) more" : "")
    }

    let read = coalescedRequest(slot: slot, count: 16)
    let scalar = scalarRequest(slot: slot)

    print("  1. is the prologue what puts the read in per-frame-ack mode?")
    // Nothing selected yet this session: does a read answer at all, and does it ack?
    print("     cold read, no 05 sent:        \(sign(try probe(read)))")
    _ = try probe(prologue(slot: slot))
    print("     after 05 \(slot):                   \(sign(try probe(read)))")
    print("     the 05 prologue itself:       \(sign(try probe(prologue(slot: slot))))")

    print("  2. does 05 take a mode byte? (05 <slot> <mode>, then one read)")
    var oddities: [String] = []
    let baseline = try probe(read)
    let baselineValue = baseline.reply?.dropFirst(15).first
    for mode in UInt8(0)...127 {
        _ = try probe(header + [0x05, slot, mode, end], settle: 0.03)
        let after = try probe(read)
        let value = after.reply?.dropFirst(15).first
        if after.ack != baseline.ack || (after.reply == nil) != (baseline.reply == nil) {
            oddities.append("mode \(mode): \(sign(after))")
        } else if value != baselineValue {
            oddities.append("mode \(mode): data changed, \(hex([value ?? 0]))")
        }
        // Put the session back on the slot under test before the next mode.
        _ = try probe(prologue(slot: slot), settle: 0.02)
    }
    print(
        oddities.isEmpty
            ? "     all 128 mode bytes behave exactly like a bare 05 -- reply then ack"
            : "     " + oddities.prefix(12).joined(separator: "\n     "))

    print("  3. do the read opcodes carry a spare field? (a flag bit, or a byte before F7)")
    var variants: [(String, [UInt8])] = []
    // nIdx is 1-3, and 4 is known to draw nothing. Anything above it is unexplored space in a
    // field the device already validates, which is where a flag would sit most cheaply.
    for bit in [0x04, 0x08, 0x10, 0x20, 0x40] as [Int] {
        var framed = read
        framed[9] = UInt8(0x03 | bit)
        variants.append(("nIdx 3|0x\(String(bit, radix: 16))", framed))
    }
    // A trailing byte after the count, and after a short read's item.
    for spare in [0x00, 0x01, 0x7F] as [UInt8] {
        variants.append(("long read + \(hex([spare]))", Array(read.dropLast()) + [spare, end]))
        variants.append(("short read + \(hex([spare]))", Array(scalar.dropLast()) + [spare, end]))
    }
    _ = try probe(prologue(slot: slot))
    for (label, frame) in variants {
        print("     \(label.padding(toLength: 22, withPad: " ", startingAt: 0)) \(sign(try probe(frame)))")
    }

    print("  4. is an unpaced window of 4 loss-free after any of that?")
    let window = steps(4, slot: slot)
    listener.collector.drain()
    for frame in window { try listener.send(frame, to: target) }
    var back = 0
    let deadline = Date().addingTimeInterval(0.3)
    while let got = listener.collector.next(within: max(0, deadline.timeIntervalSinceNow)) {
        if got.endpoint == name, got.bytes != ack, window.contains(where: { answers(got.bytes, $0) })
        {
            back += 1
        }
    }
    print("     \(back)/4 replies -- \(back == 4 ? "loss-free" : "still dropping, as before")")
}

/// What else answers? Reads only, so the whole sweep is non-destructive: a scalar read of an item
/// that does not exist draws silence, and nothing here can commit.
///
/// Two questions. Byte 7 of a request is a slot number the device echoes but does not obey -- `05`
/// is what selects the project (7.4) -- so it is a field with room in it, and a flag that turned
/// the ack off would sit there. And if the device keeps its global settings in an item of their
/// own, a scalar sweep of the item space is what finds it.
func spaceProbe(needle: String, slot: UInt8) throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let listener = try Listener()
    let target = try destination(needle, listener)
    let name = describe(target)
    try listener.send(prologue(slot: slot), to: target)
    _ = listener.listen(seconds: 0.2)

    func probe(_ frame: [UInt8], settle: Double = 0.03) throws -> (
        reply: [UInt8]?, ack: Bool
    ) {
        listener.collector.drain()
        try listener.send(frame, to: target)
        var reply: [UInt8]?
        var acked = false
        let deadline = Date().addingTimeInterval(settle)
        while let got = listener.collector.next(within: max(0, deadline.timeIntervalSinceNow)) {
            guard got.endpoint == name else { continue }
            if got.bytes == ack { acked = true } else if reply == nil { reply = got.bytes }
        }
        return (reply, acked)
    }

    print("  1. byte 7 of a long read, swept 0-127 -- does any value turn the ack off?")
    var unacked: [Int] = []
    var silent: [Int] = []
    var values: [UInt8: Int] = [:]
    for byte in UInt8(0)...127 {
        let result = try probe(coalescedRequest(slot: byte, count: 16))
        if result.reply == nil { silent.append(Int(byte)) }
        if !result.ack { unacked.append(Int(byte)) }
        if let first = result.reply?.dropFirst(15).first { values[first, default: 0] += 1 }
    }
    print("     silent: \(silent.count)   unacked: \(unacked.count)   "
        + "distinct first values: \(values.count)")
    if !unacked.isEmpty { print("     unacked at: \(unacked.prefix(16))") }

    print("  2. count byte edges -- 0, the 100 ceiling, and past it")
    for count in [0, 1, 100, 101, 127] as [UInt8] {
        let request = coalescedRequest(slot: slot, count: count)
        let result = try probe(request)
        // A reply echoes the request byte for byte and appends its values, so the values it
        // carried is the difference -- not a fixed offset, which differs by request form.
        let carried = result.reply.map { $0.count - request.count } ?? -1
        print("     count \(String(format: "%3d", Int(count))): "
            + "\(result.reply == nil ? "SILENT" : "\(carried) values back"), "
            + "\(result.ack ? "acked" : "NO ACK")")
    }

    // A scalar read answers for every item and every param, so silence cannot be used to find
    // what exists -- the device returns whatever sits at the address and validates neither field.
    // Any search for a settings area has to come from captured MCC traffic instead.
    print("  3. does an address space sweep distinguish anything? (scalar reads)")
    var itemsAnswering = 0
    var paramsAnswering = 0
    for item in UInt8(0)...127 where try probe(header + [0x01, slot, 37, item, end]).reply != nil {
        itemsAnswering += 1
    }
    for param in UInt8(0)...127
    where try probe(header + [0x01, slot, param, 120, end]).reply != nil {
        paramsAnswering += 1
    }
    print("     \(itemsAnswering)/128 items and \(paramsAnswering)/128 params answer at param 37 "
        + "/ item 120 -- no existence check, so a sweep cannot locate a settings area")
}

/// Can a lone index be walked after all? 1,567 of the walk's requests carry one index and fetch one
/// value, because a `count` walk on a request's only index repeats that index instead of advancing.
/// Collapsing each of the 100 families into a single ranged request would drop 1,467 requests --
/// about 5.9 s -- and unlike dropping the undecoded reads it loses nothing.
///
/// The idea under test is that the device walks the *last* index (7.1), so a lone index might walk
/// if it is no longer alone. Ground truth is the same addresses read one at a time; a variant is
/// only believed if it reproduces that byte for byte.
func loneProbe(needle: String, slot: UInt8, item: UInt8, param: UInt8, span: Int)
    throws
{
    setvbuf(stdout, nil, _IOLBF, 0)
    let listener = try Listener()
    let target = try destination(needle, listener)
    let name = describe(target)
    try listener.send(prologue(slot: slot), to: target)
    _ = listener.listen(seconds: 0.2)

    func values(of frame: [UInt8], asked request: [UInt8]) -> [UInt8] {
        guard frame.count > request.count else { return [] }
        return Array(frame.dropFirst(request.count - 1).dropLast())
    }

    func ask(_ request: [UInt8]) throws -> [UInt8]? {
        listener.collector.drain()
        try listener.send(request, to: target)
        var reply: [UInt8]?
        let deadline = Date().addingTimeInterval(0.08)
        while let got = listener.collector.next(within: max(0, deadline.timeIntervalSinceNow)) {
            guard got.endpoint == name, got.bytes != ack else { continue }
            if reply == nil, answers(got.bytes, request) { reply = got.bytes }
        }
        return reply
    }

    print("  item \(item), param \(param), indices 1...\(span) on slot \(slot)")

    var truth: [UInt8] = []
    for index in 1...span {
        let request = header + [0x0B, slot, param, 0x01, item, UInt8(index), 1, end]
        guard let reply = try ask(request) else { truth.append(0xEE); continue }
        truth.append(contentsOf: values(of: reply, asked: request))
    }
    print("  one at a time (\(span) requests, the ground truth): \(hex(truth))")

    let flat = header + [0x0B, slot, param, 0x01, item, 1, UInt8(span), end]
    if let reply = try ask(flat) {
        let got = values(of: reply, asked: flat)
        print("  nIdx=1, count \(span):                        \(hex(got))"
            + "  \(got == truth ? "<- WALKS" : "<- repeats, as known")")
    } else {
        print("  nIdx=1, count \(span):                        SILENT")
    }

    // The walked index goes last, so the dummy leads; the other order is tried too in case the
    // device walks the first index of a two-index request instead.
    for dummy in [0, 1, 2] as [UInt8] {
        let trailing = header + [0x0B, slot, param, 0x02, item, dummy, 1, UInt8(span), end]
        let leading = header + [0x0B, slot, param, 0x02, item, 1, dummy, UInt8(span), end]
        for (label, request) in [("(\(dummy), idx)", trailing), ("(idx, \(dummy))", leading)] {
            guard let reply = try ask(request) else {
                print("  nIdx=2 \(label), count \(span):                 SILENT")
                continue
            }
            let got = values(of: reply, asked: request)
            let verdict =
                got == truth
                ? "<- WALKS, and matches the ground truth"
                : (Set(got).count == 1 ? "<- one value repeated" : "<- different data")
            print("  nIdx=2 \(label), count \(span):                 \(hex(got))  \(verdict)")
        }
    }
}

/// Does a `count` walk that overruns its last index roll into the next middle index, or pad? The
/// earlier probe ran on a near-empty project, where "padding" and "an empty next slice" look the
/// same; this asks a slot whose next slice holds data, so the two answers differ.
func rolloverProbe(needle: String, slot: UInt8, item: UInt8, mid: UInt8) throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let listener = try Listener()
    let target = try destination(needle, listener)
    let name = describe(target)
    try listener.send(prologue(slot: slot), to: target)
    _ = listener.listen(seconds: 0.2)

    func ask(_ request: [UInt8]) throws -> [UInt8] {
        listener.collector.drain()
        try listener.send(request, to: target)
        var out: [UInt8] = []
        let deadline = Date().addingTimeInterval(0.2)
        while let got = listener.collector.next(within: max(0, deadline.timeIntervalSinceNow)) {
            guard got.endpoint == name, got.bytes != ack, answers(got.bytes, request) else {
                continue
            }
            out = Array(got.bytes.dropFirst(request.count - 1).dropLast())
            break
        }
        return out
    }

    func note(_ mid1: UInt8, _ mid2: UInt8, count: UInt8) -> [UInt8] {
        header + [0x0B, slot, 109, 0x03, item, mid1, mid2, 1, count, end]
    }

    let first = try ask(note(mid, 1, count: 64))
    let next = try ask(note(mid, 2, count: 64))
    let over = try ask(note(mid, 1, count: 100))

    print("  \(item)_109_\(mid)_1, count  64: \(first.count) values, \(hex(first.suffix(8))) (tail)")
    print("  \(item)_109_\(mid)_2, count  64: \(next.count) values, \(hex(next.prefix(8))) (head)")
    print("  \(item)_109_\(mid)_1, count 100: \(over.count) values")
    guard over.count >= 100, first.count >= 64, next.count >= 36 else {
        print("  short replies -- inconclusive")
        return
    }
    let overrun = Array(over[64..<100])
    print("     values 1-64  match the plain read: \(Array(over[0..<64]) == first)")
    print("     values 65-100:                     \(hex(overrun))")
    print("     == the next middle index's head?   \(overrun == Array(next[0..<36]))")
    print("     all one value (padding)?           \(Set(overrun).count == 1)")
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
    case "cadence":
        try cadenceProbe(needle: needle, slot: try requestedSlot(), rounds: 200, wait: 1.5)
    case "pipeline":
        try pipelineProbe(needle: needle, slot: try requestedSlot(), rounds: 50, wait: 1.5)
    case "grid":
        try gridProbe(needle: needle, slot: try requestedSlot(), rounds: 100, wait: 1.5)
    case "handshake":
        try handshakeProbe(needle: needle, slot: try requestedSlot())
    case "space":
        try spaceProbe(needle: needle, slot: try requestedSlot())
    case "rollover":
        try rolloverProbe(
            needle: needle, slot: try requestedSlot(),
            item: arguments.count > 3 ? (UInt8(arguments[3]) ?? 124) : 124,
            mid: arguments.count > 4 ? (UInt8(arguments[4]) ?? 1) : 1)
    case "lone":
        guard arguments.count > 5 else { throw ProbeError("lone needs an item, a param and a span") }
        try loneProbe(
            needle: needle, slot: try requestedSlot(), item: UInt8(arguments[3]) ?? 121,
            param: UInt8(arguments[4]) ?? 38, span: Int(arguments[5]) ?? 16)
    case "pipereplay":
        guard arguments.count > 5 else {
            throw ProbeError("pipereplay needs a plan file, a window and a pace in microseconds")
        }
        try pipeReplayProbe(
            needle: needle, slot: try requestedSlot(), path: arguments[3],
            window: Int(arguments[4]) ?? 1, pace: (Double(arguments[5]) ?? 0) / 1_000_000,
            wait: arguments.count > 6 ? (Double(arguments[6]) ?? 1500) / 1000 : 1.5)
    case "replay":
        guard arguments.count > 3 else { throw ProbeError("replay needs a plan file") }
        try replayProbe(
            needle: needle, slot: try requestedSlot(), path: arguments[3], wait: 1.5)
    case "sniff": try sniffProbe(seconds: Double(needle) ?? 20)
    default:
        print(
            "usage: coremidi_probe [list | exchange <name> <slot> | slots <name> "
                + "| throughput <name> <slot> | cadence <name> <slot> "
                + "| pipeline <name> <slot> | grid <name> <slot> "
                + "| handshake <name> <slot> | space <name> <slot> "
                + "| lone <name> <slot> <item> <param> <span> | rollover <name> <slot> "
                + "| pipereplay <name> <slot> <plan.txt> <window> <pace-us> [wait-ms] "
                + "| replay <name> <slot> <plan.txt> | sniff <seconds>]")
        exit(2)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
