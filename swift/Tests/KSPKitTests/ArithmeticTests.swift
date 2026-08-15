import Testing

@testable import KSPKit

/// The four divergences M12's port has to survive, pinned against what CPython actually returns.
///
/// Every expectation here was produced by running the Python expression rather than reasoned
/// about, because the whole point of the file is that reasoning about these is what goes wrong.
@Suite struct ArithmeticTests {
    @Test func floorDivFloorsWhereSwiftWouldTruncate() {
        // `-7 / 4` is -1 in Swift and -2 in Python; the positive cases agree and are here to show
        // the helper is not simply shifting everything by one.
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
        // The `-(-n // m)` idiom `midi_import` uses to round a step count up to the bar and to
        // count the patterns a track splits into.
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
        // Two notes can share a tick and a pitch, so the tie is real rather than hypothetical.
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
