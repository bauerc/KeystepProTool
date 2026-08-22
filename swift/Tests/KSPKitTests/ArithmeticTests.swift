import Testing

@testable import KSPKit

/// Every expectation was produced by running the Python expression, not reasoned about.
@Suite struct ArithmeticTests {
    @Test func floorDivFloorsWhereSwiftWouldTruncate() {
        // `-7 / 4` is -1 in Swift and -2 in Python; the positive cases agree.
        #expect(Arithmetic.floorDiv(-7, 4) == -2)
        #expect(Arithmetic.floorDiv(7, 4) == 1)
        #expect(Arithmetic.floorDiv(-8, 4) == -2)
        #expect(Arithmetic.floorDiv(-1, 12) == -1)
        #expect(Arithmetic.floorDiv(7, -4) == -2)
    }

    @Test func floorModTakesTheSignOfTheDivisor() {
        #expect(Arithmetic.floorMod(-7, 4) == 1)
        #expect(Arithmetic.floorMod(7, 4) == 3)
        #expect(Arithmetic.floorMod(-1, 12) == 11)
        #expect(Arithmetic.floorMod(7, -4) == -1)
    }

    @Test func ceilDivRoundsTheQuotientUp() {
        #expect(Arithmetic.ceilDiv(7, 4) == 2)
        #expect(Arithmetic.ceilDiv(8, 4) == 2)
        #expect(Arithmetic.ceilDiv(129, 64) == 3)
        #expect(Arithmetic.ceilDiv(1, 64) == 1)
    }

    @Test func pyRoundBreaksTiesToEven() {
        // Swift's `rounded()` breaks away from zero, so 2.5 would be 3 and -1.5 would be -2.
        #expect(Arithmetic.pyRound(0.5) == 0)
        #expect(Arithmetic.pyRound(1.5) == 2)
        #expect(Arithmetic.pyRound(2.5) == 2)
        #expect(Arithmetic.pyRound(3.5) == 4)
        #expect(Arithmetic.pyRound(-0.5) == 0)
        #expect(Arithmetic.pyRound(-1.5) == -2)
        #expect(Arithmetic.pyRound(-2.5) == -2)
        #expect(Arithmetic.pyRound(120.5) == 120)
        #expect(Arithmetic.pyRound(0.49999) == 0)
    }

    @Test func stableSortedKeepsTheInputOrderOfEqualElements() {
        let input = [
            (key: 1, tag: "a"), (key: 0, tag: "b"), (key: 1, tag: "c"), (key: 0, tag: "d"),
        ]
        let sorted = input.stableSorted { $0.key < $1.key }
        #expect(sorted.map(\.tag) == ["b", "d", "a", "c"])
    }

    @Test func stableSortedStillSorts() {
        #expect([3, 1, 2].stableSorted(by: <) == [1, 2, 3])
        #expect([Int]().stableSorted(by: <) == [])
    }
}
