/// What `src/ksp/` raises, carried across as one type.
///
/// The Python package signals exactly two failures -- `ValueError` for a value the format cannot
/// hold and `TypeError` for a file whose shape differs from every sample we have. Keeping the
/// distinction, and the message, is what lets the ported tests assert the same things.
public enum KSPError: Error, Equatable, CustomStringConvertible {
    case value(String)
    case type(String)

    public var description: String {
        switch self {
        case .value(let message), .type(let message): message
        }
    }
}
