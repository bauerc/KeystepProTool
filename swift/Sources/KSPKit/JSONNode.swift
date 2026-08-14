/// An ordered JSON value, and a serialiser that reproduces `json.dumps(..., indent=2)` exactly.
///
/// The dump's `--json` is one of the two ports' shared contracts -- M10's check is that the Swift
/// and the Python emit the same bytes for the same file -- and `JSONEncoder` cannot produce them.
/// It gives no control over key order beyond "sorted or synthesised", and it renders an integral
/// `Double` as `120` where Python writes `120.0`, which would differ on every tempo and every
/// whole-numbered gate.
///
/// So the model's `toJSON()` methods build one of these instead of conforming to `Encodable`, and
/// the key order in each of them is the Python `to_dict`'s insertion order.
public enum JSONNode: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONNode])

    /// Members in the order they were written, not sorted: a Python dict preserves insertion
    /// order and that order is what reaches the output.
    indirect case object([(String, JSONNode)])

    /// The rendered JSON, indented two spaces per level.
    public func serialised() -> String {
        var out = ""
        write(into: &out, depth: 0)
        return out
    }

    private func write(into out: inout String, depth: Int) {
        switch self {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .int(let value):
            out += String(value)
        case .double(let value):
            // Swift's `description` is the shortest representation that round-trips and keeps the
            // `.0` on whole numbers, which is exactly Python's `repr` for every value this format
            // holds: tempos and gate lengths, all far from the exponent thresholds where the two
            // spellings would part company.
            out += value.description
        case .string(let value):
            out += Self.quoted(value)
        case .array(let items):
            guard !items.isEmpty else {
                out += "[]"
                return
            }
            out += "[\n"
            let inner = Self.indent(depth + 1)
            for (offset, item) in items.enumerated() {
                out += inner
                item.write(into: &out, depth: depth + 1)
                out += offset == items.count - 1 ? "\n" : ",\n"
            }
            out += Self.indent(depth) + "]"
        case .object(let members):
            guard !members.isEmpty else {
                out += "{}"
                return
            }
            out += "{\n"
            let inner = Self.indent(depth + 1)
            for (offset, member) in members.enumerated() {
                out += inner + Self.quoted(member.0) + ": "
                member.1.write(into: &out, depth: depth + 1)
                out += offset == members.count - 1 ? "\n" : ",\n"
            }
            out += Self.indent(depth) + "}"
        }
    }

    private static func indent(_ depth: Int) -> String {
        String(repeating: " ", count: depth * 2)
    }

    /// Python's `json.encoder.py_encode_basestring_ascii`: the five short escapes, `\uXXXX` in
    /// lower-case hex for everything else outside printable ASCII, and surrogate pairs above the
    /// basic plane. `ensure_ascii` is on by default there, so this is on here too.
    ///
    /// Internal rather than private: `LenientJSON`'s writer escapes by the same rules, because
    /// Python reaches for this same function from both `json.dumps` and `lenient_json.dumps`.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for unit in value.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x20...0x7E: out.unicodeScalars.append(Unicode.Scalar(unit)!)
            default: out += "\\u" + hex4(unit)
            }
        }
        return out + "\""
    }

    private static func hex4(_ unit: UInt16) -> String {
        let digits = "0123456789abcdef"
        return String(
            (0..<4).reversed().map { shift in
                digits[digits.index(digits.startIndex, offsetBy: Int(unit >> (shift * 4) & 0xF))]
            })
    }
}

extension JSONNode: Equatable {
    /// Hand-written because a `[(String, JSONNode)]` payload is a tuple array, which blocks the
    /// synthesised conformance. Keeping the tuple is worth it: it is what makes a `toJSON()` read
    /// as the Python dict literal it is a port of.
    public static func == (lhs: JSONNode, rhs: JSONNode) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.int(let a), .int(let b)): a == b
        case (.double(let a), .double(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }
}
