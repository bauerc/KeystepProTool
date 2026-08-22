/// A parsed `.KeyStepPro` file: one flat object, all of whose structure lives in the key names.
public typealias RawProject = [String: JSONValue]

/// One value out of a `.KeyStepPro` file.
public enum JSONValue: Sendable, Hashable {
    case int(Int)
    case string(String)

    /// Anything else JSON allows, kept as the name of what it held.
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
