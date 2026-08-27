public enum KSPError: Error, Equatable, CustomStringConvertible {
    case value(String)
    case type(String)

    case key(String)

    /// A segmentation refused rather than adjusted; its own case so a caller can
    /// answer a boundary differently from a conversion that failed.
    case segment(String)

    public var description: String {
        switch self {
        case .value(let message), .type(let message), .key(let message),
            .segment(let message):
            message
        }
    }
}
