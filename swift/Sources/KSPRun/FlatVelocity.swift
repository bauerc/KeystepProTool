import KSPKit
import KSPMIDI

/// Parse `text` into a velocity, unvalidated -- the options type does the range check.
public func parseFlatVelocity(_ text: String?) throws -> Int? {
    guard let text else { return nil }
    if text == "fresh" { return MIDIExport.defaultFlatVelocity }
    guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else {
        throw KSPError.value("--flat-velocity: '\(text)' is not 'fresh' or a velocity")
    }
    // Python's ints are unbounded, so a numeral too big for `Int` must still reach the range
    // message rather than this one. Saturating to `.max` puts this side there too.
    return Int(text) ?? .max
}
