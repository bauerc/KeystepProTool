import AppKit
import Foundation
import KSPKit
import SwiftUI
import Testing

@testable import KSPApp

/// WCAG 2.1 contrast ratio, which is the measure rule 1 of the visual language is written against.
private func contrast(_ one: Color, _ other: Color) -> Double {
    let high = max(one.relativeLuminance, other.relativeLuminance)
    let low = min(one.relativeLuminance, other.relativeLuminance)
    return (high + 0.05) / (low + 0.05)
}

/// HSB saturation: how much of a hue a fill still wears, whatever ground it was washed over.
private func saturation(_ color: Color) -> Double {
    NSColor(color).usingColorSpace(.sRGB).map { Double($0.saturationComponent) } ?? 0
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

    @Test func arowHeadIsAsWideAsTheThingsInIt() {
        #expect(AppLayout.gridWidth <= AppLayout.minimumCardContentWidth)
        #expect(AppLayout.limitRowWidth <= AppLayout.minimumCardContentWidth)
    }

    @Test func eitherDirectionsOptionBandFitsThePane() {
        #expect(
            AppLayout.bandWidth(AppLayout.exportBandWidths) <= AppLayout.minimumCardContentWidth)
        #expect(
            AppLayout.bandWidth(AppLayout.importBandWidths) <= AppLayout.minimumCardContentWidth)
        #expect(AppLayout.keepWidths.count == 3)
    }

    @Test func therestingMapHasArowPerTrackColourAndFitsThePane() {
        #expect(AppLayout.rowCount == DeviceColor.track.count)
        #expect(AppLayout.gridWidth <= AppLayout.minimumContentWidth)
    }

    @Test func themapAtRestSitsUnderAnythingHoldingNotes() {
        #expect(Density.resting > 0)
        #expect(Density.resting < Density.floor)
        #expect(Density.restingTargeted > Density.resting)
    }

    @Test func adeviceCardFitsThePaneAndItsSlotRowFitsTheCard() {
        #expect(AppLayout.deviceCardWidth <= AppLayout.minimumContentWidth)
        #expect(
            AppLayout.slotPickerWidth + 2 * AppLayout.cardPadding <= AppLayout.deviceCardWidth)
    }

    @Test func acardLeavesTheMapRoomAtTheSmallestWindow() {
        #expect(AppLayout.minimumCardContentWidth < AppLayout.minimumContentWidth)
        #expect(AppLayout.gridWidth <= AppLayout.minimumCardContentWidth)
    }

    @Test func ameterFillsFromNothingUpToTheWall() {
        let ramp = (0...Constants.poolCapacity).map {
            AppLayout.meterFill(used: $0, limit: Constants.poolCapacity)
        }

        #expect(ramp.first == 0)
        #expect(ramp.dropFirst().allSatisfy { $0 >= 1 })
        #expect(ramp == ramp.sorted())
        #expect(ramp.last == AppLayout.meterSegmentCount)
    }

    @Test func ameterHoldsAtTheWallRatherThanRunningPastIt() {
        #expect(AppLayout.meterFill(used: 400, limit: 192) == AppLayout.meterSegmentCount)
        #expect(AppLayout.meterFill(used: 8, limit: 0) == 0)
        #expect(AppLayout.meterFill(used: -4, limit: 192) == 0)
    }

    /// The last segment is the wall: rounding to nearest lit it at 63 of 64 steps, which left a
    /// figure short of a limit drawing the same meter as one that reached it.
    @Test func ameterKeepsItsLastSegmentForTheWall() {
        #expect(AppLayout.meterFill(used: 191, limit: 192) == AppLayout.meterSegmentCount - 1)
        #expect(AppLayout.meterFill(used: 63, limit: 64) == AppLayout.meterSegmentCount - 1)
        #expect(AppLayout.meterFill(used: 64, limit: 64) == AppLayout.meterSegmentCount)
    }

    @Test func densityRisesWithNotesPerStepAndStaysBetweenItsBounds() {
        let ramp = (0...32).map { Density.opacity(notes: $0, steps: 16) }

        #expect(ramp == ramp.sorted())
        #expect(ramp[0] == 0)
        #expect(ramp.dropFirst().allSatisfy { (Density.floor...Density.ceiling).contains($0) })
    }

    @Test func densityClampsPastTheSaturationPoint() {
        let saturated = Density.opacity(notes: 32, steps: 16)

        #expect(abs(saturated - Density.ceiling) < 0.0001)
        #expect(Density.opacity(notes: 200, steps: 16) == saturated)
        #expect(Density.opacity(notes: 8, steps: 0) == 0)
    }

    /// Rule 1: hue never carries text contrast.
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

    @Test func everyLaneRegionTakesAReadableInkAndMarksThatReadOnIt() {
        for palette in [Palette.standard, Palette.chroma] {
            for track in 1...4 {
                let fill = DeviceColor.track(track).over(palette.ground, alpha: palette.laneWash)
                let ink = DeviceColor.ink(on: fill)
                let mark = ink.over(fill, alpha: AppLayout.markInkOpacity)
                #expect(contrast(ink, fill) >= 4.5, "track \(track) figure")
                #expect(contrast(mark, fill) >= 3, "track \(track) marks")
            }
        }
    }

    @Test func thestandardLaneWearsEachHueAtLeastAsStronglyAsTheChroma() {
        for track in 1...4 {
            let washed = { (palette: Palette) in
                saturation(DeviceColor.track(track).over(palette.ground, alpha: palette.laneWash))
            }
            #expect(washed(.standard) >= washed(.chroma), "track \(track)")
        }
    }

    @Test func alitWellsDigitsReadInBothFaces() {
        for palette in [Palette.standard, Palette.chroma] {
            #expect(contrast(palette.wellInk, palette.well) >= 4.5)
        }
    }

    @Test func anameFieldNeverOutshoutsTheTextBesideIt() {
        for palette in [Palette.standard, Palette.chroma] {
            #expect(
                contrast(palette.surface, palette.ground) < contrast(palette.ink, palette.ground))
        }
        #expect(
            contrast(.white, Palette.chroma.ground)
                > contrast(Palette.chroma.ink, Palette.chroma.ground))
    }

    @Test func anameFieldReadsInBothFaces() {
        for palette in [Palette.standard, Palette.chroma] {
            #expect(contrast(palette.ink, palette.surface) >= 4.5)
            #expect(contrast(palette.mutedInk, palette.surface) >= 4.5)
            #expect(
                contrast(palette.rule, palette.surface) > contrast(palette.surface, palette.ground))
        }
    }

    @Test func eachUnitReachesAppKitAsTheFaceItsPaletteIsChosenBy() {
        #expect(Appearance.system.nsAppearance == nil)
        #expect(Appearance.standard.nsAppearance?.name == .aqua)
        #expect(Appearance.chroma.nsAppearance?.name == .darkAqua)
        for unit in Appearance.allCases {
            #expect((unit.nsAppearance == nil) == (unit.colorScheme == nil))
        }
    }

    @Test func blendingAtTheEndsReturnsTheGroundAndThenTheHue() {
        let hue = DeviceColor.track(1)
        let ground = Palette.chroma.ground

        #expect(hue.over(ground, alpha: 0).relativeLuminance == ground.relativeLuminance)
        #expect(hue.over(ground, alpha: 1).relativeLuminance == hue.relativeLuminance)
    }
}
