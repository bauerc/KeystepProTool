/// Reproduces `json.dumps(..., indent=2)`; `JSONEncoder` controls neither key order nor the
/// `120` vs `120.0` rendering of a whole `Double`.
public enum JSONNode: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONNode])

    /// In the order written, not sorted, matching the Python dict's insertion order.
    indirect case object([(String, JSONNode)])

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
            // `description` keeps the `.0` on whole numbers, as Python's `repr` does.
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

    /// Python's `py_encode_basestring_ascii`: lower-case `\uXXXX` outside printable ASCII.
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
