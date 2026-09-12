import Foundation

func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}

/// "A", "A and B", "A, B and C".
func listed(_ phrases: [String]) -> String {
    guard let last = phrases.last else { return "" }
    guard phrases.count > 1 else { return last }
    return phrases.dropLast().joined(separator: ", ") + " and " + last
}

func located(_ patterns: [Int]) -> String {
    let ordered = Set(patterns).sorted()
    guard let first = ordered.first, let last = ordered.last else { return "no pattern" }
    return ordered.count == 1 ? "pattern \(first)" : "patterns \(first)-\(last)"
}

func patternReadout(_ pattern: Int?) -> String {
    pattern.map { String(format: "%02d", $0) } ?? "--"
}

func aloud(_ text: String) -> String {
    text
        .replacingOccurrences(of: " · ", with: ", ")
        .replacingOccurrences(of: " — ", with: ", ")
        .replacingOccurrences(of: "–", with: " to ")
        .replacingOccurrences(of: #"(\d)-(\d)"#, with: "$1 to $2", options: .regularExpression)
}
