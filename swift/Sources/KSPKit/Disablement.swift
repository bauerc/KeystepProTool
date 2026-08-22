/// The two ways a user switches a note off. Not audibility: the spec lists four other reasons a
/// note might not play (spec 4).
public enum Disablement: Sendable, Hashable {
    case stepTurnedOff
    case pastLastStep
}

/// Why this note will not play, or `nil` when the user has left it on.
public func disablement(_ note: Note, lastStep: Int?) -> Disablement? {
    if !note.active { return .stepTurnedOff }
    if let lastStep, note.step > lastStep { return .pastLastStep }
    return nil
}
