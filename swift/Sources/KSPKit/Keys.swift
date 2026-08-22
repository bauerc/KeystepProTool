/// `<itemId>_<paramId>[_<idx1>][_<idx2>][_<idx3>]` (spec 2).
public enum Keys {
    public static func itemForTrack(_ track: Int) throws -> Int {
        guard 1...Constants.trackItemIDs.count ~= track else {
            throw KSPError.value("track \(track) out of range 1-\(Constants.trackItemIDs.count)")
        }
        return Constants.trackItemIDs[track - 1]
    }

    public static func key(_ item: Int, _ param: Int, _ indices: Int...) -> String {
        key(item, param, indices: indices)
    }

    public static func key(_ item: Int, _ param: Int, indices: [Int]) -> String {
        guard !indices.isEmpty else { return "\(item)_\(param)" }
        return "\(item)_\(param)_" + indices.map(String.init).joined(separator: "_")
    }

    public static func getInt(
        _ raw: RawProject, _ item: Int, _ param: Int, _ indices: Int...
    ) throws -> Int? {
        try value(raw, key(item, param, indices: indices))
    }

    public static func getInt(
        _ raw: RawProject, _ item: Int, _ param: Int, indices: [Int]
    ) throws -> Int? {
        try value(raw, key(item, param, indices: indices))
    }

    /// The file's indices run 1..N; the result is 0-based, so `result[0]` is the file's index 1.
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
