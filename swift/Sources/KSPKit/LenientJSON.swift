import Foundation

/// Reading and writing MIDI Control Center's non-standard JSON dialect.
///
/// MCC parses its own files with Boost.PropertyTree, which tolerates a trailing comma before a
/// closing brace. Strict parsers do not, so every `.KeyStepPro` file in existence fails strict
/// parsing (spec section 2). A port of `src/ksp/lenient_json.py`: the read side tolerates that
/// comma, the write side omits it, which is the only part of the dialect shown to be optional.
///
/// The writer cannot be `JSONEncoder` -- it indents with spaces, appends a final newline and
/// guarantees no key order, none of which looks wrong in the output.
public enum LenientJSON {
    /// Remove MCC's trailing comma by searching backwards from the end.
    ///
    /// MCC writes one comma, right before the final closing brace. Scanning backwards finds it
    /// without touching the 3.5 MB body, and anchoring on the brace is what keeps a comma inside
    /// a string value -- or one ending an inner array -- out of reach.
    public static func strippingTrailingComma(_ data: Data) -> Data {
        guard let brace = data.lastIndex(of: UInt8(ascii: "}")) else { return data }
        guard let comma = data[..<brace].lastIndex(of: UInt8(ascii: ",")) else { return data }

        let between = data[data.index(after: comma)..<brace]
        guard between.allSatisfy(isJSONWhitespace) else { return data }
        return data[..<comma] + data[data.index(after: comma)...]
    }

    /// Parse MCC's dialect from raw bytes. `loads` on the Python side.
    ///
    /// Throws ``KSPError/value(_:)`` if the text does not parse, or parses to something other
    /// than an object.
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

    /// Parse a `.KeyStepPro` file from disk. `load_path` on the Python side.
    public static func load(contentsOf url: URL) throws -> RawProject {
        try parse(Data(contentsOf: url))
    }

    /// The two string-valued keys, in the order MCC writes them, ahead of every numeric key.
    ///
    /// Everything else in the file is an integer parameter -- even project names, which are
    /// stored as character codes.
    public static let leadingKeys = ["device", "version"]

    /// Serialise in MCC's dialect, in the order the entries arrive in. `dumps` on the Python side.
    ///
    /// Ordering is ``canonical(_:)``'s job, so this stays a faithful dumper. A `RawProject`
    /// satisfies the constraint too, at whatever order its `Dictionary` happens to hold, so a
    /// caller wanting MCC's order has to ask for it.
    ///
    /// Throws ``KSPError/type(_:)`` for anything but an integer or a string: a float would
    /// serialise as `1.0` and a bool as `true`, neither of which the firmware accepts.
    public static func serialise<Entries: Sequence>(_ entries: Entries) throws -> String
    where Entries.Element == (key: String, value: JSONValue) {
        var out = "{\n"
        // Roughly the width of one line of a real project, to save 3.5 MB of regrowth.
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

    /// Write to `url` as MCC would. `dump_path` on the Python side.
    ///
    /// Bytes rather than text, so no platform rewrites the line endings or appends a final
    /// newline (spec section 2). Atomically, because the destination is often MCC's Templates
    /// folder, where a half-written 3.5 MB file would be found and parsed.
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
    /// `126_99_16` before `126_99_2` (spec section 2).
    ///
    /// Ordered pairs rather than a mapping, because a Swift `Dictionary` has none of its own to
    /// carry. A converter starting from `Default.KeyStepPro` has to add the `version` key it
    /// lacks, and a dictionary would leave it nowhere in particular.
    public static func canonical(_ project: RawProject) -> [(key: String, value: JSONValue)] {
        let leading = leadingKeys.compactMap { name in
            project[name].map { (key: name, value: $0) }
        }
        let leadingSet = Set(leadingKeys)
        // Swift's `<` on these keys agrees with Python's `sorted`: they are ASCII, where its
        // canonical ordering and Python's code-point ordering are the same.
        let rest = project.keys.filter { !leadingSet.contains($0) }.sorted()

        return leading + rest.compactMap { name in project[name].map { (key: name, value: $0) } }
    }

    /// Why a document did not parse, in Python's words where Python has any.
    ///
    /// A failure at the root is the wrong *kind* of file rather than a broken one -- a JSON array
    /// or a bare number decodes fine and is still not a project -- so it gets Python's message
    /// and the type name to go with it. Anything deeper is malformed text.
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

    /// The flat object a `.KeyStepPro` file is, decoded key by key.
    ///
    /// `JSONDecoder` rather than `JSONSerialization` so that `1` and `true` stay distinguishable:
    /// serialisation hands both back as `NSNumber` and telling them apart again means reaching
    /// for CoreFoundation, which is exactly the kind of platform-specific detail `KSPKit` is
    /// meant not to carry.
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
            // Everything below here is a shape no file we have has ever held. It is kept, named
            // the way Python names it, so that the caller reading it reports the same thing.
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

    /// What the document holds at the top level, for the message a non-object gets.
    ///
    /// Read off the first byte rather than out of the decoder's English, and named as Python
    /// names it so both ports refuse the wrong file the same way.
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
