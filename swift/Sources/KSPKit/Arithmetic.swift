public enum Arithmetic {
    /// Floors, where Swift's `/` truncates: `-7 / 4` is -1 there and -2 here.
    public static func floorDiv(_ dividend: Int, _ divisor: Int) -> Int {
        let (quotient, remainder) = dividend.quotientAndRemainder(dividingBy: divisor)
        return remainder != 0 && (remainder < 0) != (divisor < 0) ? quotient - 1 : quotient
    }

    /// The result takes the sign of the divisor, where Swift's `%` takes the dividend's.
    public static func floorMod(_ dividend: Int, _ divisor: Int) -> Int {
        let remainder = dividend % divisor
        return remainder != 0 && (remainder < 0) != (divisor < 0) ? remainder + divisor : remainder
    }

    public static func ceilDiv(_ dividend: Int, _ divisor: Int) -> Int {
        -floorDiv(-dividend, divisor)
    }

    /// Breaks a tie to even, where `rounded()` breaks it away from zero.
    public static func roundHalfToEven(_ value: Double) -> Int {
        Int(value.rounded(.toNearestOrEven))
    }

    /// 0.5 rather than 0.500000, and 2 rather than 2.0.
    public static func general(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

extension Sequence {
    /// Equal elements keep their input order, which Swift's `sorted` does not guarantee.
    public func stableSorted(
        by areInIncreasingOrder: (Element, Element) throws -> Bool
    ) rethrows -> [Element] {
        try enumerated()
            .sorted { left, right in
                if try areInIncreasingOrder(left.element, right.element) { return true }
                if try areInIncreasingOrder(right.element, left.element) { return false }
                return left.offset < right.offset
            }
            .map(\.element)
    }
}
