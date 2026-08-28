public enum KSPError: Error, Equatable, CustomStringConvertible {
    case value(String)
    case type(String)

    case key(String)

    public var description: String {
        switch self {
        case .value(let message), .type(let message), .key(let message):
            message
        }
    }
}
