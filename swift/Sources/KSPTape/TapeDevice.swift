import Foundation

// scripts/pull_parity.sh compiles this file into one module with KSPKit's own sources, where
// KSPKit is not a module there is anything to import; under SwiftPM it is.
#if canImport(KSPKit)
    import KSPKit
#endif

/// Throwing rather than lenient: a mistyped fixture is a mistake, not a frame of zero bytes.
public func hexBytes(_ text: some StringProtocol) throws -> [UInt8] {
    var frame: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex {
        guard let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex),
            let byte = UInt8(text[index..<next], radix: 16)
        else {
            throw KSPError.value("\(text) is not a run of hex bytes")
        }
        frame.append(byte)
        index = next
    }
    return frame
}

public func hexString(_ frame: [UInt8]) -> String {
    frame.map { ($0 < 0x10 ? "0" : "") + String($0, radix: 16) }.joined()
}

/// The request a frame carries. `Sysex` parses replies; only a fake device parses requests.
public func decodeRequest(_ frame: [UInt8]) throws -> ReadRequest {
    let body = Array(frame.dropFirst(Sysex.header.count).dropLast())
    guard body.count >= 4 else { throw KSPError.value("\(hexString(frame)) is not a request") }
    if body[0] == Sysex.cmdScalar {
        return ReadRequest(item: Int(body[3]), param: Int(body[2]))
    }
    let indexCount = Int(body[3])
    guard body.count > 5 + indexCount else {
        throw KSPError.value("\(hexString(frame)) ends inside its own header")
    }
    return ReadRequest(
        item: Int(body[4]),
        param: Int(body[2]),
        indices: body[5..<(5 + indexCount)].map(Int.init),
        count: Int(body[5 + indexCount])
    )
}

public func buildReply(_ request: ReadRequest, _ values: [Int], slot: Int) -> [UInt8] {
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

/// Every address a tape delivered, as the device sent it.
public func tapeValues(contentsOf path: URL) throws -> [String: Int] {
    var values: [String: Int] = [:]
    for line in try String(contentsOf: path, encoding: .utf8).split(separator: "\n") {
        let fields = line.split(separator: " ")
        guard fields.count == 2 else { throw KSPError.value("\(line) is not <sent> <received>") }
        let (request, payload) = try Sysex.parseReply(hexBytes(fields[1]))
        guard request == (try decodeRequest(hexBytes(fields[0]))) else {
            throw KSPError.value("\(line) answers a different address than it asks")
        }
        for (name, value) in zip(try BulkRead.keysFor(request), payload) {
            values[name] = value
        }
    }
    return values
}

/// Answers any address from a tape's values, the way the device answers it -- including its
/// refusal to walk a lone index (spec 7.8).
public final class TapeDevice: Transport {
    private let values: [String: Int]
    /// Answers everything with the filler byte, as a slot holding nothing saved does.
    private let filler: Bool
    /// Echoes this slot rather than the one asked about; nil echoes the slot asked about,
    /// which is what the walk's own check needs to pass.
    private let echoing: Int?

    /// What the walk put on the wire, which is what the gate is judged by.
    public private(set) var asked: [ReadRequest] = []
    public private(set) var sent: [[UInt8]] = []
    public private(set) var slots: Set<Int> = []
    public private(set) var identified = 0

    public init(_ values: [String: Int], filler: Bool = false, echoing: Int? = nil) {
        self.values = values
        self.filler = filler
        self.echoing = echoing
    }

    /// Answers `KSPRun.PullDevice`, which a target below KSPRun cannot name.
    public func identify() throws -> String {
        identified += 1
        return Constants.projectVersion
    }

    public func send(_ frame: [UInt8]) throws {
        sent.append(frame)
    }

    /// The slot echoed back is the one asked about, so the walk's own check of it is exercised.
    public func exchange(_ frame: [UInt8]) throws -> [UInt8] {
        let request = try decodeRequest(frame)
        asked.append(request)
        let slot = try Sysex.parseSlot(frame)
        slots.insert(slot)
        let names = try BulkRead.keysFor(request)
        guard !filler else {
            return buildReply(
                request, Array(repeating: BulkRead.filler, count: names.count),
                slot: echoing ?? slot)
        }
        var payload = try names.map { name in
            guard let value = values[name] else {
                throw KSPError.value("tape holds no value for \(name)")
            }
            return value
        }
        if let count = request.count, request.indices.count == 1, count > 1 {
            // Measured on hardware: a range read over a lone index comes back as the first
            // entry repeated, whatever the later entries hold.
            payload = Array(repeating: payload[0], count: count)
        }
        return buildReply(request, payload, slot: echoing ?? slot)
    }
}
