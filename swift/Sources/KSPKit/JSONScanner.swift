import Foundation

extension UInt8 {
    var isJSONWhitespace: Bool {
        self == UInt8(ascii: " ") || self == UInt8(ascii: "\t") || self == UInt8(ascii: "\n")
            || self == UInt8(ascii: "\r")
    }
}

/// MCC's dialect scanned by hand rather than through `JSONDecoder`, which cost 88 % of a read
/// (Read_Cost.md §4). Indexes a raw pointer: in the debug builds the parity scripts run, a
/// bounds-checked subscript costs more than the scan does.
struct JSONScanner {
    enum Failure: Error {
        case notAnObject(String)
        case malformed(String, at: Int)
    }

    private let bytes: UnsafePointer<UInt8>
    private let count: Int
    private var index = 0

    init?(_ raw: UnsafeRawBufferPointer) {
        guard let base = raw.baseAddress, raw.count > 0 else { return nil }
        self.bytes = base.assumingMemoryBound(to: UInt8.self)
        self.count = raw.count
    }

    /// The whole document as one flat object; nested values keep only their type name, which is
    /// all `RawProject` can hold and all the format ever needs.
    mutating func project() throws -> RawProject {
        skipWhitespace()
        guard index < count else { throw Failure.malformed("the document is empty", at: index) }
        guard bytes[index] == UInt8(ascii: "{") else {
            throw Failure.notAnObject(try value().typeName)
        }
        index += 1

        // An entry runs about twenty bytes, so this over-reserves rather than rehashing 153,497.
        var project = RawProject(minimumCapacity: count / 20)

        while true {
            skipWhitespace()
            guard index < count else { throw Failure.malformed("expected a key or }", at: index) }
            // Also where MCC's trailing comma leaves us, its comma having been read as a separator.
            if bytes[index] == UInt8(ascii: "}") {
                index += 1
                break
            }

            let key = try string()
            skipWhitespace()
            guard index < count, bytes[index] == UInt8(ascii: ":") else {
                throw Failure.malformed("expected : after the key \"\(key)\"", at: index)
            }
            index += 1

            skipWhitespace()
            project[key] = try value()

            skipWhitespace()
            guard index < count else { throw Failure.malformed("expected , or }", at: index) }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            guard bytes[index] == UInt8(ascii: "}") else {
                throw Failure.malformed("expected , or } after \"\(key)\"", at: index)
            }
            index += 1
            break
        }

        skipWhitespace()
        guard index == count else {
            throw Failure.malformed("trailing content after the object", at: index)
        }
        return project
    }

    private mutating func value() throws -> JSONValue {
        guard index < count else { throw Failure.malformed("expected a value", at: index) }

        switch bytes[index] {
        case UInt8(ascii: "\""):
            return .string(try string())
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try number()
        case UInt8(ascii: "["):
            try skipNesting()
            return .other("list")
        case UInt8(ascii: "{"):
            try skipNesting()
            return .other("dict")
        case UInt8(ascii: "t"):
            try expect("true")
            return .other("bool")
        case UInt8(ascii: "f"):
            try expect("false")
            return .other("bool")
        case UInt8(ascii: "n"):
            try expect("null")
            return .other("NoneType")
        default:
            throw Failure.malformed("expected a value", at: index)
        }
    }

    /// Every value the format holds is an integer, so a number no `Int` represents -- a fraction,
    /// an exponent, or one too large -- takes the name Python would give it and is rejected above.
    private mutating func number() throws -> JSONValue {
        let start = index
        let negative = bytes[index] == UInt8(ascii: "-")
        if negative { index += 1 }

        let digitsStart = index
        var magnitude = 0
        var tooLarge = false
        while index < count, let digit = digitValue(bytes[index]) {
            let (shifted, overflowed) = magnitude.multipliedReportingOverflow(by: 10)
            let (grown, carried) = shifted.addingReportingOverflow(digit)
            tooLarge = tooLarge || overflowed || carried
            magnitude = grown
            index += 1
        }
        guard index > digitsStart else { throw Failure.malformed("expected a number", at: start) }

        let fractional = consumingFractionalPart()
        guard !tooLarge, !fractional else { return .other("float") }
        return .int(negative ? -magnitude : magnitude)
    }

    /// Consumes whatever follows the digits, and answers whether any of it made this a float.
    private mutating func consumingFractionalPart() -> Bool {
        var fractional = false
        while index < count {
            switch bytes[index] {
            case UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"):
                fractional = true
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "-"):
                break
            default:
                return fractional
            }
            index += 1
        }
        return fractional
    }

    private mutating func string() throws -> String {
        guard index < count, bytes[index] == UInt8(ascii: "\"") else {
            throw Failure.malformed("expected a quoted string", at: index)
        }
        index += 1

        let start = index
        var escaped = false
        while index < count {
            switch bytes[index] {
            case UInt8(ascii: "\""):
                let span = UnsafeBufferPointer(start: bytes + start, count: index - start)
                index += 1
                return escaped
                    ? try unescaping(span, from: start) : String(decoding: span, as: UTF8.self)
            case UInt8(ascii: "\\"):
                escaped = true
                index += 1
                guard index < count else {
                    throw Failure.malformed("the escape is not finished", at: index)
                }
            case 0..<0x20:
                throw Failure.malformed("a raw control byte inside a string", at: index)
            default:
                break
            }
            index += 1
        }
        throw Failure.malformed("the string is never closed", at: start - 1)
    }

    /// Only strings that carry a backslash reach this; the scan hands the rest straight to
    /// `String(decoding:as:)`. *start* is where the span sits, so offsets stay absolute.
    private func unescaping(_ span: UnsafeBufferPointer<UInt8>, from start: Int) throws -> String {
        var out: [UInt8] = []
        out.reserveCapacity(span.count)

        var i = 0
        while i < span.count {
            guard span[i] == UInt8(ascii: "\\") else {
                out.append(span[i])
                i += 1
                continue
            }
            i += 1
            guard i < span.count else {
                throw Failure.malformed("the escape is not finished", at: start + i)
            }

            switch span[i] {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(span[i])
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                UTF8.encode(try scalar(span, at: &i, from: start)) { out.append($0) }
                continue
            default:
                throw Failure.malformed(
                    "\\\(Character(Unicode.Scalar(span[i]))) is not a JSON escape", at: start + i)
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// One `\u` escape, or the surrogate pair standing for a scalar above the basic plane.
    /// Leaves *i* on the byte after what it read.
    private func scalar(_ span: UnsafeBufferPointer<UInt8>, at i: inout Int, from start: Int)
        throws -> Unicode.Scalar
    {
        let leading = try hex4(span, at: i + 1, from: start)
        i += 5
        // Everything but a surrogate is already a scalar; a surrogate needs its other half.
        if let single = Unicode.Scalar(leading) { return single }

        guard leading <= 0xDBFF else { throw Failure.malformed("a lone surrogate", at: start + i) }
        guard i + 5 < span.count, span[i] == UInt8(ascii: "\\"), span[i + 1] == UInt8(ascii: "u")
        else {
            throw Failure.malformed("a high surrogate with no low surrogate", at: start + i)
        }
        let trailing = try hex4(span, at: i + 2, from: start)
        guard 0xDC00...0xDFFF ~= trailing else {
            throw Failure.malformed("a high surrogate with no low surrogate", at: start + i)
        }
        i += 6

        return Unicode.Scalar(0x1_0000 + ((leading - 0xD800) << 10) + (trailing - 0xDC00))!
    }

    private func hex4(_ span: UnsafeBufferPointer<UInt8>, at offset: Int, from start: Int) throws
        -> UInt32
    {
        guard offset + 4 <= span.count else {
            throw Failure.malformed("a \\u escape cut short", at: start + offset)
        }

        var value: UInt32 = 0
        for byte in span[offset..<(offset + 4)] {
            guard let digit = Character(Unicode.Scalar(byte)).hexDigitValue else {
                throw Failure.malformed("a \\u escape without four hex digits", at: start + offset)
            }
            value = value << 4 | UInt32(digit)
        }
        return value
    }

    /// A nested array or object, which the format never holds: walked only far enough to find
    /// where it ends, so that the key after it still parses.
    private mutating func skipNesting() throws {
        let start = index
        var depth = 0
        while index < count {
            switch bytes[index] {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 {
                    index += 1
                    return
                }
            case UInt8(ascii: "\""):
                _ = try string()
                continue
            default:
                break
            }
            index += 1
        }
        throw Failure.malformed("the nested value is never closed", at: start)
    }

    private mutating func expect(_ word: String) throws {
        let start = index
        for byte in word.utf8 {
            guard index < count, bytes[index] == byte else {
                throw Failure.malformed("expected \(word)", at: start)
            }
            index += 1
        }
    }

    private func digitValue(_ byte: UInt8) -> Int? {
        UInt8(ascii: "0")...UInt8(ascii: "9") ~= byte ? Int(byte - UInt8(ascii: "0")) : nil
    }

    private mutating func skipWhitespace() {
        while index < count, bytes[index].isJSONWhitespace { index += 1 }
    }
}
