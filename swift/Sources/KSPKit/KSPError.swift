/// A value the format cannot hold, a file whose shape is unknown, or a miscomputed key.
public enum KSPError: Error, Equatable, CustomStringConvertible {
    case value(String)
    case type(String)

    /// `mutate`'s refusal to invent a key; the read path never raises it.
    case key(String)

    public var description: String {
        switch self {
        case .value(let message), .type(let message), .key(let message): message
        }
    }
}
