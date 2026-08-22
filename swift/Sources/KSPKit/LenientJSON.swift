import Foundation

/// Reading and writing MCC's JSON dialect: Boost.PropertyTree tolerates a trailing comma before
/// the closing brace, so every `.KeyStepPro` file fails strict parsing (spec 2).
public enum LenientJSON {
    /// Anchoring on the final brace keeps a comma inside a string, or ending an inner array, safe.
    public static func strippingTrailingComma(_ data: Data) -> Data {
        guard let brace = data.lastIndex(of: UInt8(ascii: "}")) else { return data }
        guard let comma = data[..<brace].lastIndex(of: UInt8(ascii: ",")) else { return data }

        let between = data[data.index(after: comma)..<brace]
        guard between.allSatisfy(isJSONWhitespace) else { return data }
        return data[..<comma] + data[data.index(after: comma)...]
    }

    /// Parse MCC's dialect from raw bytes, throwing for text that is not a JSON object.
    public static func parse(_ data: Data) throws -> RawProject {
        let cleaned = strippingTrailingComma(data)
        do {
            return try JSONDecoder().decode(Document.self, from: cleaned).values
        } catch let error as DecodingError {
            throw KSPError.value(complaint(about: error, in: cleaned))
        }
    }

    /// The same, from text.
    public static func parse(_ text: String) throws -> RawProject {
        try parse(Data(text.utf8))
    }

    /// Parse a `.KeyStepPro` file from disk.
    public static func load(contentsOf url: URL) throws -> RawProject {
        try parse(Data(contentsOf: url))
    }

    /// The two string-valued keys, in the order MCC writes them, ahead of every numeric key.
    public static let leadingKeys = ["device", "version"]

    /// Serialise in MCC's dialect, in the order the entries arrive in; ordering is
    /// ``canonical(_:)``'s job. Throws for anything but an integer or a string.
    public static func serialise<Entries: Sequence>(_ entries: Entries) throws -> String
    where Entries.Element == (key: String, value: JSONValue) {
        var out = "{\n"
        out.reserveCapacity(entries.underestimatedCount * 24 + 4)

        var empty = true
        for (key, value) in entries {
            if empty { empty = false } else { out += ",\n" }
            switch value {
            case .int(let number):
                out += "\t" + JSONNode.quoted(key) + ": " + String(number)
            case .string(let text):
                out += "\t" + JSONNode.quoted(key) + ": " + JSONNode.quoted(text)
            case .other(let name):
                throw KSPError.type("\(key) holds \(name), expected int or str")
            }
        }

        return out + (empty ? "}" : "\n}")
    }

    /// Write to `url` as MCC would: bytes, so nothing rewrites line endings or appends a final
    /// newline (spec 2), and atomically, since MCC parses whatever it finds in Templates.
    public static func write<Entries: Sequence>(_ entries: Entries, to url: URL) throws
    where Entries.Element == (key: String, value: JSONValue) {
        try Data(serialise(entries).utf8).write(to: url, options: .atomic)

        // An atomic write leaves the temp file's own mode behind, so widen it as the umask allows.
        let mask = umask(0)
        umask(mask)
        try FileManager.default.setAttributes(
            [.posixPermissions: Int(0o666 & ~mask)], ofItemAtPath: url.path)
    }

    /// MCC's key order: `device`, `version`, then the numeric keys sorted **as strings** --
    /// `126_99_16` before `126_99_2` (spec 2).
    public static func canonical(_ project: RawProject) -> [(key: String, value: JSONValue)] {
        let leading = leadingKeys.compactMap { name in
            project[name].map { (key: name, value: $0) }
        }
        let leadingSet = Set(leadingKeys)
        // These keys are ASCII, where Swift's `<` and Python's code-point ordering agree.
        let rest = project.keys.filter { !leadingSet.contains($0) }.sorted()

        return leading + rest.compactMap { name in project[name].map { (key: name, value: $0) } }
    }

    /// Why a document did not parse, in Python's words: a failure at the root is the wrong kind
    /// of file, anything deeper is malformed text.
    private static func complaint(about error: DecodingError, in data: Data) -> String {
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            context.codingPath.isEmpty
                ? "expected a JSON object, got \(topLevelTypeName(data))"
                : "could not parse: \(context.debugDescription)"
        case .keyNotFound(_, let context), .dataCorrupted(let context):
            "could not parse: \(context.debugDescription)"
        @unknown default:
            "could not parse: \(error)"
        }
    }

    /// The flat object a `.KeyStepPro` file is. `JSONDecoder`, not `JSONSerialization`, which
    /// hands back `1` and `true` alike as `NSNumber`.
    private struct Document: Decodable {
        let values: RawProject

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Name.self)
            var values = RawProject(minimumCapacity: container.allKeys.count)
            for key in container.allKeys {
                values[key.stringValue] = try Self.value(from: container, at: key)
            }
            self.values = values
        }

        private static func value(
            from container: KeyedDecodingContainer<Name>, at key: Name
        ) throws -> JSONValue {
            if let number = try? container.decode(Int.self, forKey: key) {
                return .int(number)
            }
            if let text = try? container.decode(String.self, forKey: key) {
                return .string(text)
            }
            // Shapes no real file holds, named as Python names them so both ports report alike.
            if (try? container.decode(Bool.self, forKey: key)) != nil {
                return .other("bool")
            }
            if (try? container.decode(Double.self, forKey: key)) != nil {
                return .other("float")
            }
            if try container.decodeNil(forKey: key) {
                return .other("NoneType")
            }
            if (try? container.nestedUnkeyedContainer(forKey: key)) != nil {
                return .other("list")
            }
            return .other("dict")
        }

        private struct Name: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }

            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
    }

    /// What the document holds at the top level, read off the first byte and named as Python
    /// names it, for the message a non-object gets.
    private static func topLevelTypeName(_ data: Data) -> String {
        switch data.first(where: { !isJSONWhitespace($0) }) {
        case UInt8(ascii: "["): "list"
        case UInt8(ascii: "\""): "str"
        case UInt8(ascii: "t"), UInt8(ascii: "f"): "bool"
        case UInt8(ascii: "n"): "NoneType"
        case .some(let byte) where byte == UInt8(ascii: "-") || (byte >= 0x30 && byte <= 0x39):
            data.contains(UInt8(ascii: ".")) ? "float" : "int"
        default: "unknown"
        }
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
