// The Swift core's pull, over a captured exchange instead of the device.
//
// Usage: pulltape <tape.txt> <slot> <template.KeyStepPro> <out.KeyStepPro>. Compiled against
// KSPKit alone by scripts/pull_parity.sh, which is the only caller: `ksp-swift-cli pull` opens
// the hardware, and the gate has to run where there is none.

import Foundation

/// The request a frame carries. `Sysex` parses replies; only a fake device parses requests.
private func decodeRequest(_ frame: [UInt8]) -> ReadRequest {
    let body = Array(frame.dropFirst(Sysex.header.count).dropLast())
    if body[0] == Sysex.cmdScalar {
        return ReadRequest(item: Int(body[3]), param: Int(body[2]))
    }
    let indexCount = Int(body[3])
    return ReadRequest(
        item: Int(body[4]), param: Int(body[2]),
        indices: body[5..<(5 + indexCount)].map(Int.init), count: Int(body[5 + indexCount]))
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

private func hexBytes(_ text: some StringProtocol) -> [UInt8] {
    stride(from: 0, to: text.count, by: 2).map { offset in
        let start = text.index(text.startIndex, offsetBy: offset)
        return UInt8(text[start...text.index(after: start)], radix: 16) ?? 0
    }
}

/// Answers any address from a tape's values, at any count the device allows.
private final class TapeDevice: Transport {
    private let values: [String: Int]

    init(tape: URL) throws {
        var values: [String: Int] = [:]
        for line in try String(contentsOf: tape, encoding: .utf8).split(separator: "\n") {
            let fields = line.split(separator: " ")
            let (request, payload) = try Sysex.parseReply(hexBytes(fields[1]))
            for (name, value) in zip(try BulkRead.keysFor(request), payload) {
                values[name] = value
            }
        }
        self.values = values
    }

    func send(_ frame: [UInt8]) throws {}

    func exchange(_ frame: [UInt8]) throws -> [UInt8] {
        let request = decodeRequest(frame)
        let payload = try BulkRead.keysFor(request).map { name in
            guard let value = values[name] else {
                throw KSPError.value("the tape holds no value for \(name)")
            }
            return value
        }
        // Echo the slot asked about, so the walk's own check of it is exercised.
        return buildReply(request, payload, slot: try Sysex.parseSlot(frame))
    }
}

// `@main` rather than top-level code: swiftc allows that only in a file called `main.swift`.
@main
enum PullTape {
    static func main() throws {
        let arguments = CommandLine.arguments
        let device = try TapeDevice(tape: URL(filePath: arguments[1]))
        let template = try LenientJSON.load(contentsOf: URL(filePath: arguments[3]))
        let raw = try BulkRead.readRaw(
            device, templateKeys: template.keys, version: BulkRead.defaultVersion,
            slot: Int(arguments[2]) ?? Sysex.defaultSlot)
        try LenientJSON.write(LenientJSON.canonical(raw), to: URL(filePath: arguments[4]))
    }
}
