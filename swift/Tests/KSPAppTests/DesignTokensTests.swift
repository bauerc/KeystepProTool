import Foundation
import SwiftUI
import Testing

@testable import KSPApp

/// WCAG 2.1 contrast ratio, which is the measure rule 1 of the visual language is written against.
private func contrast(_ one: Color, _ other: Color) -> Double {
    let high = max(one.relativeLuminance, other.relativeLuminance)
    let low = min(one.relativeLuminance, other.relativeLuminance)
    return (high + 0.05) / (low + 0.05)
}

@Suite struct DesignTokensTests {
    @Test func alengthRuleGrowsWithTheStepsItStandsFor() {
        let widths = [16, 32, 48, 64].map { AppLayout.lengthRuleWidth(steps: $0) }

        #expect(widths == widths.sorted())
        #expect(Set(widths).count == widths.count)
        #expect(widths.last == AppLayout.cellWidth)
    }

    /// 64 is the longest a Pattern runs, so nothing above it may draw wider than the cell.
    @Test func alengthRuleStopsAtTheStepCeiling() {
        #expect(AppLayout.lengthRuleWidth(steps: 128) == AppLayout.lengthRuleWidth(steps: 64))
        #expect(AppLayout.lengthRuleWidth(steps: 65) == AppLayout.cellWidth)
    }

    @Test func aslotWithNoStepsGetsNoLengthRule() {
        #expect(AppLayout.lengthRuleWidth(steps: 0) == 0)
        #expect(AppLayout.lengthRuleWidth(steps: -4) == 0)
    }

    /// A name or a badge wider than the head is clipped in silence, which is the failure
    /// ``AppLayout/trackColumnWidths`` already warns about.
    @Test func arowHeadIsAsWideAsTheThingsInIt() {
        #expect(
            AppLayout.labelWidth
                == AppLayout.wellWidth + AppLayout.labelGap + AppLayout.rowNameWidth
                + AppLayout.labelGap + AppLayout.rowBadgeWidth)
        #expect(AppLayout.gridWidth <= AppLayout.minimumContentWidth)
    }

    @Test func densityRisesWithNotesPerStepAndStaysBetweenItsBounds() {
        let ramp = (0...32).map { Density.opacity(notes: $0, steps: 16) }

        #expect(ramp == ramp.sorted())
        #expect(ramp[0] == 0)
        #expect(ramp.dropFirst().allSatisfy { (Density.floor...Density.ceiling).contains($0) })
    }

    /// Two notes a step and a hundred fill the same: the ramp is clamped, not scaled to the file.
    @Test func densityClampsPastTheSaturationPoint() {
        let saturated = Density.opacity(notes: 32, steps: 16)

        #expect(abs(saturated - Density.ceiling) < 0.0001)
        #expect(Density.opacity(notes: 200, steps: 16) == saturated)
        #expect(Density.opacity(notes: 8, steps: 0) == 0)
    }

    /// Rule 1: hue never carries text contrast. The ink is chosen from the fill the eye actually
    /// sees, so it is the blended fill -- not the bare hue -- that every face has to pass over.
    @Test func everyTrackHueTakesAReadableInkAtEveryDensity() {
        for palette in [Palette.standard, Palette.chroma] {
            for track in 1...4 {
                for alpha in [Density.floor, Density.ceiling] {
                    let fill = DeviceColor.track(track).over(palette.ground, alpha: alpha)
                    let ratio = contrast(DeviceColor.ink(on: fill), fill)
                    #expect(ratio >= 4.5, "track \(track) at \(alpha) reads at \(ratio):1")
                }
            }
        }
    }

    @Test func blendingAtTheEndsReturnsTheGroundAndThenTheHue() {
        let hue = DeviceColor.track(1)
        let ground = Palette.chroma.ground

        #expect(hue.over(ground, alpha: 0).relativeLuminance == ground.relativeLuminance)
        #expect(hue.over(ground, alpha: 1).relativeLuminance == hue.relativeLuminance)
    }
}
