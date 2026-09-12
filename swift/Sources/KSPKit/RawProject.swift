public typealias RawProject = [String: JSONValue]

public enum JSONValue: Sendable, Hashable {
    case int(Int)
    case string(String)

    case other(String)

    /// The name a diagnostic prints: `str`, not `String`. Pinned by the CLI's output contract.
    public var typeName: String {
        switch self {
        case .int: "int"
        case .string: "str"
        case .other(let name): name
        }
    }
}
