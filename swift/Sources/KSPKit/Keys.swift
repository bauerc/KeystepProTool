/// The `.KeyStepPro` key grammar: `<itemId>_<paramId>[_<idx1>][_<idx2>][_<idx3>]` (spec 2).
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

    /// Read one integer value; `nil` is a key that does not apply, not a failure.
    public static func getInt(
        _ raw: RawProject, _ item: Int, _ param: Int, _ indices: Int...
    ) throws -> Int? {
        try value(raw, key(item, param, indices: indices))
    }

    /// The same, for a caller that already holds its indices in an array.
    public static func getInt(
        _ raw: RawProject, _ item: Int, _ param: Int, indices: [Int]
    ) throws -> Int? {
        try value(raw, key(item, param, indices: indices))
    }

    /// Read a 1-based indexed array as a 0-based Swift array, so `result[0]` is the file's index 1.
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
