import KSPKit
import KSPMIDI

/// The `--flat-velocity` grammar. A port of `src/ksp_cli/flat_velocity.py`.
///
/// `fresh` or a bare number, which `ExportOptions` already range-checks. Parsing lives here rather
/// than in the argument declaration for the same reason as `Selection.swift`: the two CLIs' output
/// is a byte-for-byte contract.

/// Parse `text` into a velocity, unvalidated -- `ExportOptions` does the range check.
///
/// `nil` and `"fresh"` are today's "no override" and "the measured default" spellings; a bare
/// numeral passes through so both cores raise the identical message for `0` or an out-of-range
/// value.
public func parseFlatVelocity(_ text: String?) throws -> Int? {
    guard let text else { return nil }
    if text == "fresh" { return MIDIExport.defaultFlatVelocity }
    guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else {
        throw KSPError.value("--flat-velocity: '\(text)' is not 'fresh' or a velocity")
    }
    // Python's ints are unbounded, so a numeral too big for `Int` still reaches `ExportOptions`
    // and gets the range message rather than this one. Saturating to `.max` puts this side there
    // too -- there is no negative spelling to saturate towards, since a leading `-` already fails
    // the digit check above.
    return Int(text) ?? .max
}
