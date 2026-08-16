import KSPKit

/// The two ways a note is switched off. Both are toggled the same way on the device, so both read
/// as "disabled" and name their reason rather than inventing separate words.
///
/// These are rows 2 and 3 of the spec's six reasons a note might not play (§4, existence versus
/// audibility). The other four -- velocity 0, the step-skip mask, randomness, and an empty pool
/// entry -- are not disablement, so nothing here claims a note is audible, only that the user has
/// not switched it off.
enum Disablement {
    case stepTurnedOff
    case pastLastStep
}

/// Why this note will not play, or `nil` when the user has left it on.
///
/// Stated once because two callers need it: the dump prints a marker beside it, `ProjectSummary`
/// counts it, and `MIDIExport.renderPattern` filters an export on the same pair.
func disablement(_ note: Note, lastStep: Int?) -> Disablement? {
    if !note.active { return .stepTurnedOff }
    if let lastStep, note.step > lastStep { return .pastLastStep }
    return nil
}
