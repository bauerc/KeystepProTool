import ArgumentParser

/// Refuses a value outside `range`, naming the option as the user typed it. The message renders the
/// bounds it just tested, so the two cannot drift apart.
func checkBound(_ option: String, _ value: Int, in range: ClosedRange<Int>) throws {
    guard range.contains(value) else {
        throw ValidationError("'--\(option)' must be in \(range.lowerBound)...\(range.upperBound)")
    }
}
