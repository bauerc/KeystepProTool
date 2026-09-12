import ArgumentParser

func checkBound(_ option: String, _ value: Int, in range: ClosedRange<Int>) throws {
    guard range.contains(value) else {
        throw ValidationError("'--\(option)' must be in \(range.lowerBound)...\(range.upperBound)")
    }
}
