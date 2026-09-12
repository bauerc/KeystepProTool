import Foundation
import Testing

@testable import KSPApp

@Suite struct ChaseTests {
    @Test func thechaseIsHeldOffUntilItsFloorHasPassed() {
        #expect(Chase.column(after: 0) == nil)
        #expect(Chase.column(after: Chase.holdOff - 0.001) == nil)
        #expect(Chase.column(after: Chase.holdOff) == 0)
    }

    @Test func aconversionShorterThanTheFloorLightsNoStepAtAll() {
        #expect(
            stride(from: 0, to: Chase.holdOff, by: 0.01).allSatisfy {
                Chase.column(after: $0) == nil
            })
    }

    @Test func theplayheadCrossesEveryColumnLeftToRight() {
        let lit = stride(
            from: Chase.holdOff, to: Chase.holdOff + Chase.sweep, by: Chase.step / 4
        ).compactMap(Chase.column(after:))

        #expect(lit == lit.sorted())
        #expect(Set(lit).count == AppLayout.columnCount)
        #expect(lit.first == 0)
        #expect(lit.last == AppLayout.columnCount - 1)
    }

    @Test func thesweepAfterItStartsFromTheLeftAgain() {
        #expect(Chase.column(after: Chase.holdOff + Chase.sweep) == 0)
        #expect(Chase.column(after: Chase.holdOff + Chase.sweep + Chase.step) == 1)
    }

    @Test(arguments: [1.0, 9.5, 60.0, 3600.0, 86_400.0])
    func aconversionOfAnyLengthStaysOnTheMap(elapsed: TimeInterval) throws {
        let column = try #require(Chase.column(after: Chase.holdOff + elapsed))

        #expect((0..<AppLayout.columnCount).contains(column))
    }
}
