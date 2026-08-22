public enum Arithmetic {
    /// Python's `//`, which floors where Swift's `/` truncates: `-7 // 4` is -2 there, -1 here.
    public static func floorDiv(_ dividend: Int, _ divisor: Int) -> Int {
        let (quotient, remainder) = dividend.quotientAndRemainder(dividingBy: divisor)
        return remainder != 0 && (remainder < 0) != (divisor < 0) ? quotient - 1 : quotient
    }

    /// Python's `%`, whose result takes the sign of the divisor.
    public static func floorMod(_ dividend: Int, _ divisor: Int) -> Int {
        let remainder = dividend % divisor
        return remainder != 0 && (remainder < 0) != (divisor < 0) ? remainder + divisor : remainder
    }

    public static func ceilDiv(_ dividend: Int, _ divisor: Int) -> Int {
        -floorDiv(-dividend, divisor)
    }

    /// Python 3's `round`, which breaks a tie to even where `rounded()` breaks it away from zero.
    public static func pyRound(_ value: Double) -> Int {
        Int(value.rounded(.toNearestOrEven))
    }

    /// Python's `f"{value:g}"`: 0.5 rather than 0.500000, and 2 rather than 2.0.
    public static func general(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

extension Sequence {
    /// Python's `sorted`, which is stable; Swift's is documented as not guaranteed to be.
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
