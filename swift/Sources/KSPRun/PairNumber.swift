import Foundation
import KSPKit

/// The largest number a pair may spell; an oversized numeral is refused by the grammar.
let maxPairNumber = 2_147_483_647

func pairInt(_ text: some StringProtocol, malformed: String, oversized: String) throws -> Int {
    // Oversized and malformed earn different messages, which `Int` alone cannot tell apart.
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var digits = Substring(body)
    if digits.first == "+" || digits.first == "-" { digits = digits.dropFirst() }
    guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
        throw KSPError.value(malformed)
    }
    // `magnitude`, not `abs`: `abs(Int.min)` traps, so a pasted `Int.min` would crash the CLI.
    guard let value = Int(body), value.magnitude <= UInt(maxPairNumber) else {
        throw KSPError.value(oversized)
    }
    return value
}
