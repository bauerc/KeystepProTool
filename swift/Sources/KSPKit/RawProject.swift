public typealias RawProject = [String: JSONValue]

public enum JSONValue: Sendable, Hashable {
    case int(Int)
    case string(String)

    case other(String)

    /// Python's name for the type, not Swift's, so both ports report a file the same way.
    public var typeName: String {
        switch self {
        case .int: "int"
        case .string: "str"
        case .other(let name): name
        }
    }
}
