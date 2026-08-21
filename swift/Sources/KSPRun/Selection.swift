import Foundation
import KSPKit

public let selectionHelp = "numbers and N-M ranges, comma-separated (e.g. 1,3 or 2-4)"

/// `nil` gives the empty set, which is how `Project.select` already spells "all of them".
public func parseSelection(_ text: String?, option: String, limit: Int) throws -> Set<Int> {
    guard let text else { return [] }
    var selected: Set<Int> = []
    for field in text.split(separator: ",", omittingEmptySubsequences: false) {
        let item = field.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = item.prefix { $0 != "-" }
        let ranged = start.count != item.count
        let first = try number(start, item: item, option: option)
        let last =
            ranged
            ? try number(item.dropFirst(start.count + 1), item: item, option: option) : first
        if last.value < first.value {
            throw KSPError.value("\(option): '\(item)' ends before it starts")
        }
        for value in first.value...last.value {
            guard 1...limit ~= value else {
                // The walk stops at `limit + 1`, so only a saturated start reaches here.
                let spelled = value == first.value ? first.spelled ?? "\(value)" : "\(value)"
                throw KSPError.value("\(option): \(spelled) is out of range 1-\(limit)")
            }
            selected.insert(value)
        }
    }
    return selected
}

/// `spelled` carries the digits only when they do not fit `Int` and `value` has been saturated.
private struct Number {
    let value: Int
    let spelled: String?
}

private func number(
    _ text: some StringProtocol, item: String, option: String
) throws -> Number {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let value = Int(trimmed) { return Number(value: value, spelled: nil) }
    // Python's ints are unbounded, so a numeral too big for `Int` is compared and printed rather
    // than rejected. Saturating leaves every comparison below on the side Python would put it.
    guard let numeral = numeral(trimmed) else {
        throw KSPError.value("\(option): '\(item)' is not a number or a range")
    }
    return Number(value: trimmed.first == "-" ? .min : .max, spelled: numeral)
}

/// `text` as Python would print the integer it spells, or `nil` if it spells none.
private func numeral(_ text: String) -> String? {
    let sign = text.first == "-" ? "-" : ""
    var digits = Substring(text)
    if digits.first == "+" || digits.first == "-" { digits = digits.dropFirst() }
    guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    let significant = digits.drop { $0 == "0" }
    return sign + (significant.isEmpty ? "0" : significant)
}
