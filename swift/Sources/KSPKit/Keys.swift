/// The `.KeyStepPro` key grammar, a port of `src/ksp/keys.py`.
///
/// All structure in these files lives in the key names -- the JSON itself is one flat object with
/// no nesting: `<itemId>_<paramId>[_<idx1>][_<idx2>][_<idx3>]` (spec section 2). Centralising key
/// construction here means the two index spaces (step-indexed vs note-indexed) are the only thing
/// a caller has to think about; getting the string right is not also their problem.
public enum Keys {
    /// The item id carrying sequencer track `track`, counting from 1.
    public static func itemForTrack(_ track: Int) throws -> Int {
        guard 1...Constants.trackItemIDs.count ~= track else {
            throw KSPError.value("track \(track) out of range 1-\(Constants.trackItemIDs.count)")
        }
        return Constants.trackItemIDs[track - 1]
    }

    /// Build a file key from an item, a parameter and any number of indices.
    public static func key(_ item: Int, _ param: Int, _ indices: Int...) -> String {
        key(item, param, indices: indices)
    }

    /// The same, for a caller that already holds its indices in an array.
    public static func key(_ item: Int, _ param: Int, indices: [Int]) -> String {
        guard !indices.isEmpty else { return "\(item)_\(param)" }
        return "\(item)_\(param)_" + indices.map(String.init).joined(separator: "_")
    }

    /// Read one integer value, or `nil` if the key is absent.
    ///
    /// Absent is meaningful rather than exceptional: the key set differs between item types (only
    /// item 123 carries drum parameters), so callers probing a parameter that may not apply get
    /// `nil` instead of a lookup error.
    ///
    /// Throws ``KSPError/type(_:)`` if the key exists but does not hold an integer. That would
    /// mean the file's shape differs from every sample we have, which is worth surfacing loudly
    /// rather than silently coercing.
    public static func getInt(
        _ raw: RawProject, _ item: Int, _ param: Int, _ indices: Int...
    ) throws -> Int? {
        try value(raw, key(item, param, indices: indices))
    }

    /// Read a 1-based indexed array as a 0-based Swift array.
    ///
    /// The trailing index in these files runs 1..N (step 1..64, or note ordinal 1..64). The
    /// result is ordinary 0-based, so `result[0]` is the file's index 1. Every caller wants one
    /// convention or the other and mixing them is how the two index spaces get confused.
    public static func readArray(
        _ raw: RawProject, _ item: Int, _ param: Int, _ prefix: Int..., length: Int
    ) throws -> [Int?] {
        let base = key(item, param, indices: prefix) + "_"
        return try (0..<length).map { try value(raw, "\(base)\($0 + 1)") }
    }

    private static func value(_ raw: RawProject, _ name: String) throws -> Int? {
        switch raw[name] {
        case nil: nil
        case .int(let value): value
        case .some(let other): throw KSPError.type("\(name) holds \(other.typeName), expected int")
        }
    }
}
