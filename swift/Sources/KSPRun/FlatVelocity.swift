import KSPKit
import KSPMIDI

public let freshVelocitySpec = "fresh"

public func parseFlatVelocity(_ text: String?) throws -> Int? {
    guard let text else { return nil }
    if text == freshVelocitySpec { return MIDIExport.defaultFlatVelocity }
    guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else {
        throw KSPError.value("--flat-velocity: '\(text)' is not 'fresh' or a velocity")
    }
    // A numeral too big for `Int` is still a number, so saturating sends it to the range check.
    return Int(text) ?? .max
}
