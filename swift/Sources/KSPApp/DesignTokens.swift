import AppKit
import SwiftUI

enum Appearance: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case standard
    case chroma

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Match system"
        case .standard: return "Standard"
        case .chroma: return "Chroma"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .standard: return .light
        case .chroma: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .standard: return NSAppearance(named: .aqua)
        case .chroma: return NSAppearance(named: .darkAqua)
        }
    }
}

enum DeviceColor {
    static let track = [
        Color(hex: 0x01_A986),  // Track 1 panel zone; a teal-leaning green, not a pure one
        Color(hex: 0xFB_5C26),  // Track 2 panel zone
        Color(hex: 0xFA_CC00),  // Track 3 panel zone
        Color(hex: 0xE0_002E),  // Track 4 panel zone
    ]

    /// §4.2.9: "the currently playing step, which is lit up in white". The conversion playhead.
    static let now = Color.white

    static func track(_ number: Int) -> Color {
        track[(number - 1 + track.count) % track.count]
    }

    private static let darkInk = Color(hex: 0x0D_0D0D)

    /// The luminance at which ``darkInk`` and white contrast equally, in WCAG's terms.
    private static let inkCrossover =
        ((0.05 + darkInk.relativeLuminance) * 1.05).squareRoot() - 0.05

    static func ink(on fill: Color) -> Color {
        fill.relativeLuminance > inkCrossover ? darkInk : .white
    }
}

struct Palette: Sendable {
    let ground: Color
    let surface: Color
    let well: Color
    let wellInk: Color
    let ink: Color
    let mutedInk: Color
    let rule: Color
    let inert: Color
    let warning: Color
    let error: Color
    let success: Color
    let laneWash: Double

    static let standard = Palette(
        ground: Color(hex: 0xE8_E9ED),  // body white, lit upper face
        surface: Color(hex: 0xDA_DDE0),  // body white, shaded front face
        well: Color(hex: 0x0D_0D0D),  // the panel's matte black band
        wellInk: Color(hex: 0xE9_F0FF),  // the lit 7-segment digits
        ink: Color(hex: 0x14_161A),  // the panel's near-black primary legends
        mutedInk: Color(hex: 0x5A_6068),
        rule: Color(hex: 0xC4_C8CE),
        inert: Color(hex: 0xCB_CFD5),
        warning: Color(hex: 0xA8_630A),
        error: Color(hex: 0x9E_1420),
        success: Color(hex: 0x1B_7A4B),
        laneWash: 0.7)

    static let chroma = Palette(
        ground: Color(hex: 0x1C_1D20),  // the dark grey shell
        surface: Color(hex: 0x24_2629),
        well: Color(hex: 0x0C_0A0B),  // an unlit panel, sampled from a powered unit
        wellInk: Color(hex: 0xE9_F0FF),
        ink: Color(hex: 0xE7_E9EC),
        mutedInk: Color(hex: 0x91_99A1),
        rule: Color(hex: 0x34_373C),
        inert: Color(hex: 0x3A_3D42),
        warning: Color(hex: 0xF2_B33C),
        error: Color(hex: 0xFF_7B86),
        success: Color(hex: 0x4E_D092),
        laneWash: 0.18)

    static func resolved(for scheme: ColorScheme) -> Palette {
        scheme == .dark ? chroma : standard
    }
}

enum Density {
    static let floor = 0.18
    static let ceiling = 0.92
    static let resting = 0.14
    static let restingTargeted = 0.42
    /// A pattern is read as full at two notes per step; chords pass that without looking different.
    static let saturationPoint = 2.0

    static func opacity(notes: Int, steps: Int) -> Double {
        guard steps > 0, notes > 0 else { return 0 }
        let perStep = Double(notes) / Double(steps)
        let scaled = min(perStep / saturationPoint, 1)
        return floor + (ceiling - floor) * scaled
    }
}

enum TypeScale {
    static let header = Font.system(.title2, design: .default).weight(.semibold)
    static let sectionTitle = Font.system(.title3, design: .default).weight(.semibold)
    static let label = Font.system(.callout, design: .default)
    static let smallLabel = Font.system(.caption2, design: .default)
    static let resultMark = Font.system(.largeTitle)

    static let value = Font.system(.caption, design: .monospaced)
    static let smallValue = Font.system(.caption2, design: .monospaced)
    static let readout = Font.system(.caption, design: .monospaced).weight(.semibold)
    static let headlineValue = Font.system(.callout, design: .monospaced)
}

enum StatusMark {
    static let warning = "exclamationmark.circle"
    static let error = "exclamationmark.triangle"
    static let success = "checkmark.circle"
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }

    var relativeLuminance: Double {
        let parts = NSColor(self).usingColorSpace(.sRGB).map {
            [$0.redComponent, $0.greenComponent, $0.blueComponent]
        }
        guard let parts else { return 0 }
        let linear = parts.map { channel -> Double in
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    func over(_ ground: Color, alpha: Double) -> Color {
        guard let top = NSColor(self).usingColorSpace(.sRGB),
            let base = NSColor(ground).usingColorSpace(.sRGB)
        else { return self }
        let mix = { (over: CGFloat, under: CGFloat) in under + (over - under) * CGFloat(alpha) }
        return Color(
            .sRGB,
            red: mix(top.redComponent, base.redComponent),
            green: mix(top.greenComponent, base.greenComponent),
            blue: mix(top.blueComponent, base.blueComponent))
    }
}

enum AppLayout {
    static let minimumWindowWidth: CGFloat = 1020
    static let minimumWindowHeight: CGFloat = 640
    static let defaultWindowWidth: CGFloat = 1120
    static let defaultWindowHeight: CGFloat = 700
    static let mainPadding: CGFloat = 18
    /// "Show scroll bars: Always" gives the staged view's `ScrollView` a scroller that takes width.
    static let scrollerAllowance: CGFloat = 15

    static let columnCount = 16
    static let rowCount = 4
    static var labelWidth: CGFloat {
        wellWidth + labelGap + rowNameWidth + labelGap + rowBadgeWidth
    }
    static let rowNameWidth: CGFloat = 68
    /// "Drum" and its capsule padding; at 34 the word truncated to "Dr...".
    static let rowBadgeWidth: CGFloat = 44
    static let labelGap: CGFloat = 8
    static let cellWidth: CGFloat = 46
    static let cellSpacing: CGFloat = 3
    static let cellHeight: CGFloat = 26

    static let trackTickWidth: CGFloat = 18
    static let trackNumberWidth: CGFloat = 22
    static let trackNameMinWidth: CGFloat = 150
    static let trackBadgeWidth: CGFloat = 78
    static let trackChannelsWidth: CGFloat = 88
    static let trackCountsWidth: CGFloat = 150
    /// "Automatic — Tracks 2, 3" is the longest a destination reads.
    static let trackDestinationWidth: CGFloat = 170
    static let trackColumnGap: CGFloat = 8

    static let limitNameWidth: CGFloat = 128
    static let limitFigureWidth: CGFloat = 62

    static var minimumContentWidth: CGFloat {
        minimumWindowWidth - 2 * mainPadding - scrollerAllowance
    }

    static var gridOrigin: CGFloat { labelWidth + labelGap }

    static var gridWidth: CGFloat {
        gridOrigin + CGFloat(columnCount) * cellWidth + CGFloat(columnCount - 1) * cellSpacing
    }

    static let trackColumnWidths: [CGFloat] = [
        trackTickWidth, trackNumberWidth, trackNameMinWidth, trackBadgeWidth, trackChannelsWidth,
        trackCountsWidth, trackDestinationWidth,
    ]

    static var trackRowWidth: CGFloat {
        trackColumnWidths.reduce(0, +) + CGFloat(trackColumnWidths.count - 1) * trackColumnGap
    }

    static func x(ofColumn index: Int) -> CGFloat {
        gridOrigin + CGFloat(index) * (cellWidth + cellSpacing)
    }

    struct Rail: Equatable {
        let x: CGFloat
        let width: CGFloat
    }

    static func rail(from: Int, to: Int) -> Rail {
        let span = CGFloat(to - from + 1)
        return Rail(
            x: x(ofColumn: from - 1), width: span * cellWidth + (span - 1) * cellSpacing)
    }

    static func rails(joining links: Set<Int>) -> [Rail] {
        var rails: [Rail] = []
        var column = 1
        while column <= columnCount {
            guard links.contains(column) else {
                column += 1
                continue
            }
            var last = column
            while links.contains(last) { last += 1 }
            rails.append(rail(from: column, to: last))
            column = last + 1
        }
        return rails
    }

    static let actionBarHeight: CGFloat = 56
    static let wellWidth: CGFloat = 26
    static let wellRadius: CGFloat = 3
    static let cellRadius: CGFloat = 3
    static let lengthRuleHeight: CGFloat = 2
    static let railHeight: CGFloat = 2
    static let stepCeiling = 64

    static func lengthRuleWidth(steps: Int) -> CGFloat {
        guard steps > 0 else { return 0 }
        return cellWidth * CGFloat(min(steps, stepCeiling)) / CGFloat(stepCeiling)
    }
    static var axisWidth: CGFloat { gridWidth - gridOrigin }
    static let laneHeight: CGFloat = 56
    static let laneSpacing: CGFloat = 3
    static let regionRadius: CGFloat = 3
    static let boundaryWidth: CGFloat = 1
    static let markHeight: CGFloat = 3
    /// A sixteenth at the default division is under a point wide once a long run is scaled down.
    static let markMinWidth: CGFloat = 1.5
    static let markInkOpacity = 0.75
    static let marksMinimumWidth: CGFloat = 14
    /// A single digit at ``TypeScale/smallValue``, which is the narrowest a number stays a number.
    static let regionLabelMinimumWidth: CGFloat = 11
    static let regionLabelInset: CGFloat = 2
    static let pitchWindowMinimumSpan = 12
    /// Closer than this, grid lines are a texture rather than a grid.
    static let gridLineMinimumSpacing: CGFloat = 8
    static let gridInkOpacity = 0.14
    static let gridAccentInkOpacity = 0.5
    static let gridAccentWidth: CGFloat = 1.5
    /// The export writes 4/4, so its bar is four beats.
    static let beatsPerBar = 4
    static let middleCInkOpacity = 0.45
    /// "C#-1" is the longest a pitch reads.
    static let pitchLabelWidth: CGFloat = 30
    static let pitchLabelHeight: CGFloat = 12
    static var shapeHeadWidth: CGFloat { gridOrigin - labelGap - pitchLabelWidth }
    static let bracketHeight: CGFloat = 14
    static let bracketTickHeight: CGFloat = 5
    /// "pattern 16 · 64 steps" at ``TypeScale/smallValue``, and the rule either side of it.
    static let bracketLabelMinimumWidth: CGFloat = 150
    static let thumbnailInset: CGFloat = 3
    static let thumbnailMarkHeight: CGFloat = 1.5

    static func x(ofTick tick: Int, in totalTicks: Int) -> CGFloat {
        guard totalTicks > 0 else { return 0 }
        return axisWidth * CGFloat(tick) / CGFloat(totalTicks)
    }

    static func width(ofTicks ticks: Int, in totalTicks: Int) -> CGFloat {
        guard totalTicks > 0, ticks > 0 else { return 0 }
        return axisWidth * CGFloat(min(ticks, totalTicks)) / CGFloat(totalTicks)
    }

    static func gridStride(unitWidth: CGFloat, group: Int) -> Int {
        guard unitWidth > 0 else { return 0 }
        let factor = max(group, 2)
        var stride = 1
        while CGFloat(stride) * unitWidth < gridLineMinimumSpacing { stride *= factor }
        return stride
    }

    static let meterSegmentWidth: CGFloat = 6
    static let meterSegmentGap: CGFloat = 2
    static let meterHeight: CGFloat = 8
    static let meterSegmentCount = 24
    static let meterSegmentRadius: CGFloat = 1
    static let meterCapWidth: CGFloat = 1.5
    static let meterCapGap: CGFloat = 3

    static var meterWidth: CGFloat {
        CGFloat(meterSegmentCount) * meterSegmentWidth
            + CGFloat(meterSegmentCount - 1) * meterSegmentGap + meterCapGap + meterCapWidth
    }

    /// The last segment is the wall: rounding to nearest would light 63 of 64 steps as full.
    static func meterFill(used: Int, limit: Int) -> Int {
        guard used > 0, limit > 0 else { return 0 }
        guard used < limit else { return meterSegmentCount }
        let lit = (Double(used) / Double(limit) * Double(meterSegmentCount)).rounded()
        return min(meterSegmentCount - 1, max(1, Int(lit)))
    }

    static var slotPickerWidth: CGFloat { axisWidth }
    static let slotCellHeight: CGFloat = 24
    static let deviceCardWidth: CGFloat = 820
    static let settingsWidth: CGFloat = 460
    static let footerDividerHeight: CGFloat = 24
    static let bandDividerHeight: CGFloat = 18
    static let bandGap: CGFloat = 12
    static let splitPickerWidth: CGFloat = 190
    static let stepSkipPickerWidth: CGFloat = 140
    static let repeatStepperWidth: CGFloat = 110
    static let drumsPickerWidth: CGFloat = 200
    static let drumChannelStepperWidth: CGFloat = 110
    static let keepLabelWidth: CGFloat = 34
    /// "Time Shift" is the longest of the three, and "Keep" the label that introduces them.
    static let keepWidths: [CGFloat] = [74, 62, 86]

    static var keepsWidth: CGFloat {
        keepLabelWidth + keepWidths.reduce(0, +) + CGFloat(keepWidths.count) * labelGap
    }

    static var exportBandWidths: [CGFloat] {
        [splitPickerWidth, stepSkipPickerWidth, repeatStepperWidth, 1, keepsWidth]
    }

    static var importBandWidths: [CGFloat] {
        [drumsPickerWidth, drumChannelStepperWidth, 1, keepsWidth]
    }

    static func bandWidth(_ widths: [CGFloat]) -> CGFloat {
        widths.reduce(0, +) + CGFloat(widths.count - 1) * bandGap
    }
    static let cardPadding: CGFloat = 12
    static let cardSpacing: CGFloat = 10
    static let cardRadius: CGFloat = 8
    static let sectionSpacing: CGFloat = 22

    static var minimumCardContentWidth: CGFloat { minimumContentWidth - 2 * cardPadding }

    static let fieldRadius: CGFloat = 5
    static let fieldPadding = EdgeInsets(top: 5, leading: 7, bottom: 5, trailing: 7)
    static let fieldRingWidth: CGFloat = 3
    static let hoverRingWidth: CGFloat = 1.5
    static let pressedOpacity: Double = 0.6

    static let findingGlyphWidth: CGFloat = 14
    /// "Track 1, pattern 16" is the longest a gauge's site reads.
    static let limitSiteWidth: CGFloat = 150

    static var limitRowWidth: CGFloat {
        limitNameWidth + meterWidth + limitFigureWidth + findingGlyphWidth + limitSiteWidth
            + 4 * labelGap
    }
}
