/// One read the device can answer, without the slot it is addressed at.
public struct ReadRequest: Sendable, Hashable {
    public let item: Int
    public let param: Int
    public let indices: [Int]
    /// nil is the index-less short form.
    public let count: Int?

    public init(item: Int, param: Int, indices: [Int] = [], count: Int? = nil) {
        self.item = item
        self.param = param
        self.indices = indices
        self.count = count
    }
}

/// The KeyStep Pro's SysEx read protocol as frames: pure encode and decode, no I/O (spec 7).
public enum Sysex {
    public static let header: [UInt8] = [0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42]
    public static let end: UInt8 = 0xF7

    public static let cmdScalar: UInt8 = 0x01
    public static let cmdScalarReply: UInt8 = 0x02
    public static let cmdRead: UInt8 = 0x0B
    public static let cmdReadReply: UInt8 = 0x0C
    public static let cmdAck: UInt8 = 0x1C

    /// Byte 7, following every command byte: the project slot the transfer names
    /// (spec 7.4). The ack is the only frame without one.
    public static let defaultSlot = 1

    /// A SysEx data byte, so 0-127 -- deliberately wider than the device's sixteen
    /// slots, because the codec is not the place to refuse an out-of-range one.
    public static let maxSlot = 0x7F

    /// The ceiling on a long read's count. Above it the device clamps and echoes the
    /// count it honoured, so the reply reads as an answer to a different question (spec 7.7).
    public static let maxReadCount = 100

    /// The one frame with no slot in byte 7; its 0x00 is a constant (spec 7.4).
    public static let ack: [UInt8] = header + [cmdAck, 0x00, end]

    /// Sent once before the first read and never answered. It selects the project
    /// slot the transfer returns; it is not a handshake.
    public static let cmdPrologue: UInt8 = 0x05

    /// Universal (non-Arturia) identity envelope. Not a handshake, but the only
    /// place the firmware version comes from.
    public static let identityRequest: [UInt8] = [0xF0, 0x7E, 0x7F, 0x06, 0x01, end]
    private static let identityPrefix: [UInt8] = [0xF0, 0x7E, 0x7F, 0x06, 0x02, 0x00, 0x20, 0x6B]

    /// The device's "pattern default pitch unset" sentinel. It is a MIDI System Reset
    /// byte, which is why MCC stores 247 instead -- the only value above 127 in a file.
    public static let unset = 0xFF
    public static let unsetInFile = 247

    /// The `05 <slot>` frame MCC opens a transfer with.
    public static func prologue(_ slot: Int = defaultSlot) throws -> [UInt8] {
        try checkSlot(slot)
        return header + [cmdPrologue, UInt8(slot), end]
    }

    /// One request frame, addressed at `slot`. The slot rides beside the request
    /// so `parseReply` can compare reply against request without it in the way.
    public static func buildReadRequest(
        _ request: ReadRequest,
        slot: Int = defaultSlot
    ) throws -> [UInt8] {
        try checkSlot(slot)
        guard let count = request.count else {
            guard request.indices.isEmpty else {
                throw KSPError.value("the short form takes no indices")
            }
            return header + [cmdScalar, UInt8(slot)]
                + (try bytes([request.param, request.item])) + [end]
        }
        guard (1...3).contains(request.indices.count) else {
            throw KSPError.value("\(request.indices.count) indices, expected 1 to 3")
        }
        guard (0...maxReadCount).contains(count) else {
            throw KSPError.value("count \(count), expected 0 to \(maxReadCount)")
        }
        let body =
            [request.param, request.indices.count, request.item] + request.indices + [count]
        return header + [cmdRead, UInt8(slot)] + (try bytes(body)) + [end]
    }

    /// The project slot a frame names. Not valid for the ack.
    public static func parseSlot(_ frame: [UInt8]) throws -> Int {
        guard frame.count >= 8, frame.starts(with: header) else {
            throw KSPError.value("not a KeyStep Pro SysEx frame")
        }
        return Int(frame[7])
    }

    public static func parseReply(_ frame: [UInt8]) throws -> (request: ReadRequest, values: [Int])
    {
        guard frame.starts(with: header), frame.last == end else {
            throw KSPError.value("not a KeyStep Pro SysEx frame")
        }

        let command = frame[6]
        if command == cmdScalarReply {
            let values = payload(of: frame, from: 10)
            guard values.count == 1 else {
                throw KSPError.value("scalar reply carried \(values.count) values, expected 1")
            }
            return (ReadRequest(item: Int(frame[9]), param: Int(frame[8])), values)
        }

        guard command == cmdReadReply else {
            throw KSPError.value("command \(hexByte(command)) is not a read reply")
        }

        guard frame.count > 9 else {
            throw KSPError.value("read reply ends inside its own header")
        }
        let indexCount = Int(frame[9])
        guard frame.count > 11 + indexCount else {
            throw KSPError.value("read reply ends inside its own header")
        }
        let count = Int(frame[11 + indexCount])
        let request = ReadRequest(
            item: Int(frame[10]),
            param: Int(frame[8]),
            indices: frame[11..<(11 + indexCount)].map(Int.init),
            count: count
        )
        let values = payload(of: frame, from: 12 + indexCount)
        guard values.count == count else {
            throw KSPError.value("reply carried \(values.count) values, header promised \(count)")
        }
        return (request, values)
    }

    /// The firmware version out of a universal identity reply.
    /// Arturia's four-byte field runs backwards: `25 14 05 02` is build 0x25 then 2.5.20.
    public static func parseIdentity(_ frame: [UInt8]) throws -> String {
        guard frame.starts(with: identityPrefix), frame.last == end else {
            throw KSPError.value("not a KeyStep Pro identity reply")
        }
        guard frame.count == 17 else {
            throw KSPError.value("identity reply is \(frame.count) bytes, expected 17")
        }
        return "\(frame[15]).\(frame[14]).\(frame[13])"
    }

    private static func checkSlot(_ slot: Int) throws {
        guard (0...maxSlot).contains(slot) else {
            throw KSPError.value("slot \(slot), expected 0 to \(maxSlot)")
        }
    }

    /// Throwing rather than trapping: a field too wide for a byte is a bad request, not a crash.
    private static func bytes(_ values: [Int]) throws -> [UInt8] {
        try values.map { value in
            guard let byte = UInt8(exactly: value) else {
                throw KSPError.value("\(value) does not fit in a byte")
            }
            return byte
        }
    }

    /// Everything between `start` and the terminator, empty where the frame ends first.
    private static func payload(of frame: [UInt8], from start: Int) -> [Int] {
        let terminator = frame.count - 1
        guard start < terminator else { return [] }
        return frame[start..<terminator].map(Int.init)
    }

    private static func hexByte(_ value: UInt8) -> String {
        "0x" + (value < 0x10 ? "0" : "") + String(value, radix: 16)
    }
}
