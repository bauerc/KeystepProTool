/// The four places Swift and Python disagree on arithmetic, in one file.
///
/// M9 found the port's bugs were never overflow -- every field in this format is 7 bits -- but
/// rounding and division. M12 hand-converts another 2,500 lines of tick arithmetic, so the
/// divergences are named here and called by both `KSPKit` and `KSPMIDI` rather than re-derived at
/// each site, where a missing `.toNearestOrEven` looks exactly like a correct one.
public enum Arithmetic {
    /// Python's `//`, which floors. Swift's `/` truncates toward zero, so the two disagree on
    /// every negative dividend: `-7 // 4` is -2 there and -1 here.
    public static func floorDiv(_ dividend: Int, _ divisor: Int) -> Int {
        let (quotient, remainder) = dividend.quotientAndRemainder(dividingBy: divisor)
        return remainder != 0 && (remainder < 0) != (divisor < 0) ? quotient - 1 : quotient
    }

    /// Python's `%`, whose result takes the sign of the divisor and so is never negative for the
    /// positive divisors used here.
    public static func floorMod(_ dividend: Int, _ divisor: Int) -> Int {
        let remainder = dividend % divisor
        return remainder != 0 && (remainder < 0) != (divisor < 0) ? remainder + divisor : remainder
    }

    /// Python's `-(-n // m)` idiom: divide and round the quotient up.
    public static func ceilDiv(_ dividend: Int, _ divisor: Int) -> Int {
        -floorDiv(-dividend, divisor)
    }

    /// Python 3's `round`, which breaks a tie to even where Swift's `rounded()` breaks it away
    /// from zero: `round(2.5)` is 2 there and 3 here.
    public static func pyRound(_ value: Double) -> Int {
        Int(value.rounded(.toNearestOrEven))
    }

    /// Python's `f"{value:g}"`: 0.5 rather than 0.500000, and 2 rather than 2.0.
    ///
    /// Both CLIs print gate lengths and tempo through this, and so does the export's off-ladder
    /// gate diagnostic, so it has to say the same thing in all three.
    public static func general(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

extension Sequence {
    /// Python's `sorted`, which is stable. Swift's is documented as not guaranteed to be.
    ///
    /// Every sort in the port carries a tuple key whose ties are real -- two notes can share a
    /// tick and a pitch -- so the input order has to survive them, or two runs of the same build
    /// can disagree about which of a pair comes first.
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
