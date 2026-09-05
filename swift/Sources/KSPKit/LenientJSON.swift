import Foundation

/// Boost.PropertyTree tolerates a trailing comma before the closing brace; strict parsers do
/// not, so every `.KeyStepPro` file fails strict parsing (spec 2).
public enum LenientJSON {
    public static func strippingTrailingComma(_ data: Data) -> Data {
        guard let brace = data.lastIndex(of: UInt8(ascii: "}")) else { return data }
        guard let comma = data[..<brace].lastIndex(of: UInt8(ascii: ",")) else { return data }

        let between = data[data.index(after: comma)..<brace]
        guard between.allSatisfy(\.isJSONWhitespace) else { return data }
        return data[..<comma] + data[data.index(after: comma)...]
    }

    public static func parse(_ data: Data) throws -> RawProject {
        do {
            return try data.withUnsafeBytes { raw in
                guard var scanner = JSONScanner(raw) else {
                    throw JSONScanner.Failure.malformed("the document is empty", at: 0)
                }
                return try scanner.project()
            }
        } catch let failure as JSONScanner.Failure {
            throw KSPError.value(complaint(about: failure))
        }
    }

    public static func parse(_ text: String) throws -> RawProject {
        try parse(Data(text.utf8))
    }

    public static func load(contentsOf url: URL) throws -> RawProject {
        try parse(Data(contentsOf: url))
    }

    public static let leadingKeys = ["device", "version"]

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

    /// Bytes, so nothing rewrites the line endings or appends a final newline (spec 2); atomic.
    public static func write<Entries: Sequence>(_ entries: Entries, to url: URL) throws
    where Entries.Element == (key: String, value: JSONValue) {
        try Data(serialise(entries).utf8).write(to: url, options: .atomic)

        let mask = umask(0)
        umask(mask)
        try FileManager.default.setAttributes(
            [.posixPermissions: Int(0o666 & ~mask)], ofItemAtPath: url.path)
    }

    /// MCC's key order: `device`, `version`, then the numeric keys sorted **as strings** (spec 2).
    public static func canonical(_ project: RawProject) -> [(key: String, value: JSONValue)] {
        let leading = leadingKeys.compactMap { name in
            project[name].map { (key: name, value: $0) }
        }
        let leadingSet = Set(leadingKeys)
        let rest = project.keys.filter { !leadingSet.contains($0) }.sorted()

        return leading + rest.compactMap { name in project[name].map { (key: name, value: $0) } }
    }

    private static func complaint(about failure: JSONScanner.Failure) -> String {
        switch failure {
        case .notAnObject(let typeName): "expected a JSON object, got \(typeName)"
        case .malformed(let reason, let offset): "could not parse: \(reason) at byte \(offset)"
        }
    }
}
