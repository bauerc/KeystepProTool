/// A parsed `.KeyStepPro` file: one flat object, all of whose structure lives in the key names.
///
/// The Python side is a plain `dict[str, Any]`; Swift needs the value type spelled out. Every
/// value in every file we have is an integer or a string, so those are the two cases that carry
/// data -- ``JSONValue/other(_:)`` is what a file outside that shape decodes to, so the caller
/// asking for it gets the same error Python raises rather than a parse that failed earlier.
public typealias RawProject = [String: JSONValue]

/// One value out of a `.KeyStepPro` file.
public enum JSONValue: Sendable, Hashable {
    case int(Int)
    case string(String)

    /// Anything else JSON allows, kept as the name of what it held. See ``typeName``.
    case other(String)

    /// The name this value goes by in an error message.
    ///
    /// Python's, not Swift's: the two ports report the same file the same way, and a user
    /// comparing them should not have to work out that `str` and `String` are the same complaint.
    public var typeName: String {
        switch self {
        case .int: "int"
        case .string: "str"
        case .other(let name): name
        }
    }
}
