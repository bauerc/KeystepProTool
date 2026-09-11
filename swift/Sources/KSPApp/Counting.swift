import Foundation

/// Pluralised by the count, for the several views that say "3 notes" or "1 bar".
func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}

/// "A", "A and B", "A, B and C".
func listed(_ phrases: [String]) -> String {
    guard let last = phrases.last else { return "" }
    guard phrases.count > 1 else { return last }
    return phrases.dropLast().joined(separator: ", ") + " and " + last
}

/// Where a track's Patterns sit, worded as `convert` words it, so both previews and the result
/// read alike. Named once each: a repeated run plays the same Pattern several times.
func located(_ patterns: [Int]) -> String {
    let ordered = Set(patterns).sorted()
    guard let first = ordered.first, let last = ordered.last else { return "no pattern" }
    return ordered.count == 1 ? "pattern \(first)" : "patterns \(first)-\(last)"
}

/// A pattern number or a project slot, two digits as the device's four displays show it, or `--`
/// where the track is on no pattern at all. Shared so every readout reads the same way round.
func patternReadout(_ pattern: Int?) -> String {
    pattern.map { String(format: "%02d", $0) } ?? "--"
}

/// A tooltip's words for a reader who hears them: its separators become pauses, and a dash between
/// two figures becomes "to" rather than a minus.
func aloud(_ text: String) -> String {
    text
        .replacingOccurrences(of: " · ", with: ", ")
        .replacingOccurrences(of: " — ", with: ", ")
        .replacingOccurrences(of: "–", with: " to ")
        .replacingOccurrences(of: #"(\d)-(\d)"#, with: "$1 to $2", options: .regularExpression)
}
