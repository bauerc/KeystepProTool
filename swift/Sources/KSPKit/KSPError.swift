/// What `src/ksp/` raises, carried across as one type.
///
/// The Python package signals three failures -- `ValueError` for a value the format cannot hold,
/// `TypeError` for a file whose shape differs from every sample we have, and `KeyError` for an
/// address the fixed key set does not carry, which means it was computed wrongly. Keeping the
/// distinction, and the message, is what lets the ported tests assert the same things.
public enum KSPError: Error, Equatable, CustomStringConvertible {
    case value(String)
    case type(String)

    /// `mutate`'s refusal to invent a key. M12; the read path never raises it.
    case key(String)

    public var description: String {
        switch self {
        case .value(let message), .type(let message), .key(let message): message
        }
    }
}
