// Read a project off the device over CoreMIDI and write the .KeyStepPro (issue #245).
//
// A `KSPKit.Transport` over CoreMIDI plus `BulkRead.readRaw`: no format logic lives here, so what
// it proves is the transport. Standalone until #246 gives it a target.
//
//   (cd swift && swift build --target KSPKit)
//   swiftc -O -I swift/.build/debug/Modules tools/coremidi_read.swift \
//       swift/.build/debug/KSPKit.build/*.o -o /tmp/coremidi_read
//   /tmp/coremidi_read <slot> <out.KeyStepPro> [template.KeyStepPro]
//
// The objects rather than `-lKSPKit`: `swift build --target` compiles the target without
// archiving a library, and this tool is not a package target that SwiftPM would link for us.

import CoreMIDI
import Foundation
import KSPKit

let sysexEnd: UInt8 = 0xF7
let ackFrame: [UInt8] = [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42, 0x1C, 0x00, sysexEnd]

struct ReadError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw ReadError("\(what) failed: OSStatus \(status)") }
}

func displayName(_ endpoint: MIDIEndpointRef) -> String {
    var value: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value) == noErr,
        let value
    else { return "?" }
    return value.takeRetainedValue() as String
}

/// Whole SysEx messages off the input port, as a blocking queue.
final class Frames: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var queue: [[UInt8]] = []
    private let arrived = DispatchSemaphore(value: 0)

    func feed(_ bytes: [UInt8]) {
        var completed = 0
        lock.lock()
        for byte in bytes {
            // Real-time bytes may interleave a SysEx stream. `0xFF` is not one of them here: it
            // never reaches us at all, because CoreMIDI cuts the frame at it (spec 7.9.1).
            if (0xF8...0xFE).contains(byte) { continue }
            if byte == 0xF0 {
                pending = [byte]
            } else if !pending.isEmpty {
                pending.append(byte)
                if byte == sysexEnd {
                    queue.append(pending)
                    pending = []
                    completed += 1
                }
            }
        }
        lock.unlock()
        for _ in 0..<completed { arrived.signal() }
    }

    func next(within seconds: Double) -> [UInt8]? {
        guard arrived.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return queue.isEmpty ? nil : queue.removeFirst()
    }
}

/// The device over CoreMIDI, repairing the one thing the wire will not carry.
final class CoreMIDITransport: Transport {
    private let frames = Frames()
    private let timeout: Double
    private var client = MIDIClientRef()
    private var input = MIDIPortRef()
    private var output = MIDIPortRef()
    private let target: MIDIEndpointRef
    private(set) var requests = 0
    private(set) var repaired = 0

    init(matching needle: String, timeout: Double = 1.5) throws {
        self.timeout = timeout
        let sources = (0..<MIDIGetNumberOfSources()).map(MIDIGetSource)
        let destinations = (0..<MIDIGetNumberOfDestinations()).map(MIDIGetDestination)
        guard
            let found = destinations.first(where: {
                displayName($0).localizedCaseInsensitiveContains(needle)
            })
        else { throw ReadError("no CoreMIDI destination matching \"\(needle)\"") }
        target = found

        try check(MIDIClientCreateWithBlock("ksp-read" as CFString, &client, nil), "client")
        let frames = self.frames
        try check(
            MIDIInputPortCreateWithBlock(client, "in" as CFString, &input) { packets, _ in
                var packet = packets.pointee.packet
                for _ in 0..<packets.pointee.numPackets {
                    frames.feed(
                        withUnsafeBytes(of: packet.data) { Array($0.prefix(Int(packet.length))) })
                    packet = MIDIPacketNext(&packet).pointee
                }
            }, "input port")
        try check(MIDIOutputPortCreate(client, "out" as CFString, &output), "output port")
        for source in sources { MIDIPortConnectSource(input, source, nil) }
    }

    func send(_ frame: [UInt8]) throws {
        var builder = MIDIPacketList()
        let packet = MIDIPacketListInit(&builder)
        MIDIPacketListAdd(
            &builder, MemoryLayout<MIDIPacketList>.size, packet, 0, frame.count, frame)
        try check(MIDISend(output, target, &builder), "send")
    }

    func exchange(_ request: [UInt8]) throws -> [UInt8] {
        requests += 1
        let reply = try once(request)
        guard let short = shortfall(reply, request) else { return reply }
        return try repair(request, reply, missingFrom: short)
    }

    /// One transaction: the request, then frames until the ack ends it (spec 7.1).
    private func once(_ request: [UInt8]) throws -> [UInt8] {
        try send(request)
        var reply: [UInt8]?
        let deadline = Date().addingTimeInterval(timeout)
        while let frame = frames.next(within: max(0, deadline.timeIntervalSinceNow)) {
            if frame == ackFrame { break }
            reply = frame
        }
        guard let reply else {
            throw ReadError("no reply to \(hexOf(request)) within \(timeout)s")
        }
        return reply
    }

    /// How many values a reply is missing, or nil when it is whole. A long reply's echoed count is
    /// the promise; anything less arrived truncated at a `0xFF` (spec 7.9.1).
    private func shortfall(_ reply: [UInt8], _ request: [UInt8]) -> Int? {
        guard reply.count > 6, reply[6] == 0x0C, request.count > 8 else { return nil }
        let promised = Int(request[request.count - 2])
        let carried = reply.count - request.count
        return carried < promised ? carried : nil
    }

    /// Rebuilds a truncated reply: the value after the ones that arrived is the sentinel, and the
    /// rest is re-read from the next index on. Costs one exchange per sentinel.
    private func repair(_ request: [UInt8], _ reply: [UInt8], missingFrom carried: Int) throws
        -> [UInt8]
    {
        let promised = Int(request[request.count - 2])
        let firstIndex = Int(request[request.count - 3])
        var values = Array(reply.dropFirst(request.count - 1).dropLast())
        values.append(UInt8(Sysex.unset))
        repaired += 1

        var next = carried + 1
        while next < promised {
            var tail = request
            tail[tail.count - 3] = UInt8(firstIndex + next)
            tail[tail.count - 2] = UInt8(promised - next)
            let answer = try once(tail)
            let got = answer.count - tail.count
            values.append(contentsOf: answer.dropFirst(tail.count - 1).dropLast())
            if got < promised - next {
                values.append(UInt8(Sysex.unset))
                repaired += 1
                next += got + 1
            } else {
                next = promised
            }
        }
        return Array(reply.dropLast(reply.count - (request.count - 1))) + values + [sysexEnd]
    }
}

func hexOf(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

// MARK: - main

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, let slot = Int(arguments[0]) else {
    print("usage: coremidi_read <slot> <out.KeyStepPro> [template.KeyStepPro]")
    exit(2)
}
let outputPath = arguments[1]
let templatePath =
    arguments.count > 2 ? arguments[2] : "src/ksp_cli/templates/Default.KeyStepPro"

do {
    let template = try LenientJSON.load(contentsOf: URL(fileURLWithPath: templatePath))
    let transport = try CoreMIDITransport(matching: "KeyStep Pro")

    let started = Date()
    let raw = try BulkRead.readRaw(transport, templateKeys: template.keys, slot: slot)
    let elapsed = Date().timeIntervalSince(started)

    try LenientJSON.write(LenientJSON.canonical(raw), to: URL(fileURLWithPath: outputPath))
    print(
        "slot \(slot): \(raw.count) keys, \(transport.requests) requests, "
            + "\(transport.repaired) sentinels repaired, "
            + "\(String(format: "%.2f", elapsed))s -> \(outputPath)")
} catch {
    print("error: \(error)")
    exit(1)
}
