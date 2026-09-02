import SwiftUI

/// Which KeyStep Pro the app dresses as. The device ships in two finishes and the app has a face
/// for each, so the choice is which unit is on the desk rather than light or dark.
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

    /// `nil` leaves the window following the system, which is the macOS contract and the default.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .standard: return .light
        case .chroma: return .dark
        }
    }
}

/// Colours the device itself assigns, and what it assigns them to. Values are sampled from
/// Arturia's own product imagery except where the manual states them; both faces share them,
/// because a track's identity does not change with the finish.
enum DeviceColor {
    /// Manual 2.5.2 §1.4: "Green for Track 1, Orange for Track 2, Yellow for Track 3 and Red for
    /// Track 4" -- painted on the panel and lit on the step buttons alike.
    static let track = [
        Color(hex: 0x01_A986),  // Track 1 panel zone; a teal-leaning green, not a pure one
        Color(hex: 0xFB_5C26),  // Track 2 panel zone
        Color(hex: 0xFA_CC00),  // Track 3 panel zone
        Color(hex: 0xE0_002E),  // Track 4 panel zone
    ]

    /// §4.2.9: "the currently playing step, which is lit up in white". The conversion playhead.
    static let now = Color.white

    /// §4.2.14: the 63 SHIFT functions are silkscreened in blue, so blue means secondary function.
    /// A marker only -- see ``Palette`` on why it never carries text.
    static let secondary = Color(hex: 0x16_B4E9)

    /// Tracks are numbered from 1; a row asks for its own colour by that number.
    static func track(_ number: Int) -> Color {
        track[(number - 1 + track.count) % track.count]
    }

    /// The panel's own near-black legend colour, which is what stands in for black as an ink.
    private static let darkInk = Color(hex: 0x0D_0D0D)

    /// The luminance at which ``darkInk`` and white contrast equally against a fill, in WCAG's own
    /// terms. Choosing by it holds every fill at 4.4:1 or better; a higher threshold leaves a band
    /// of mid fills -- track 1's green over the standard ground among them -- wearing white ink at
    /// under 3:1, which is the failure rule 1 of the visual language exists to prevent.
    private static let inkCrossover =
        ((0.05 + darkInk.relativeLuminance) * 1.05).squareRoot() - 0.05

    /// Black or white, whichever the eye can read on `fill`. Track hues run from a mid green to a
    /// dark red, so no single ink serves all four.
    static func ink(on fill: Color) -> Color {
        fill.relativeLuminance > inkCrossover ? darkInk : .white
    }
}

/// One authored face. Neither is derived from the other: light is the standard unit, dark is the
/// Chroma, and both are real products.
struct Palette: Sendable {
    /// The window behind everything.
    let ground: Color
    /// A recessed panel the pattern map and the meters sit in.
    let surface: Color
    /// The dark strip across the top, after the panel's own matte band.
    let band: Color
    /// Text and figures on ``band`` and in a readout well.
    let bandInk: Color
    /// The dark well behind a row's pattern number, after the four 7-segment displays.
    let well: Color
    /// Primary text.
    let ink: Color
    /// Supporting text, and an unticked slot cell's figure.
    let mutedInk: Color
    /// Hairlines, borders and the empty part of a limit meter.
    let rule: Color
    /// A source track not yet routed, and a slot cell holding nothing.
    let inert: Color
    /// Warning status. Deliberately duller and darker than ``DeviceColor`` track 2's orange, which
    /// it can sit beside; the glyph and the sort order carry severity, and this only agrees.
    let warning: Color
    /// Error status, held apart from track 4's red on the same reasoning as ``warning``.
    let error: Color
    /// Success, which no track colour claims.
    let success: Color

    /// The standard unit: an off-white metal wedge with a matte black control band.
    static let standard = Palette(
        ground: Color(hex: 0xE8_E9ED),  // body white, lit upper face
        surface: Color(hex: 0xDA_DDE0),  // body white, shaded front face
        band: Color(hex: 0x0D_0D0D),  // the matte black control band
        bandInk: Color(hex: 0xE9_F0FF),  // the lit 7-segment digits
        well: Color(hex: 0x0D_0D0D),
        ink: Color(hex: 0x14_161A),  // the panel's near-black primary legends
        mutedInk: Color(hex: 0x5A_6068),
        rule: Color(hex: 0xC4_C8CE),
        inert: Color(hex: 0xCB_CFD5),
        warning: Color(hex: 0xA8_630A),
        error: Color(hex: 0x9E_1420),
        success: Color(hex: 0x1B_7A4B))

    /// The Chroma: a dark grey shell with icy blue indicators.
    static let chroma = Palette(
        ground: Color(hex: 0x1C_1D20),  // the dark grey shell
        surface: Color(hex: 0x24_2629),
        band: Color(hex: 0x0C_0A0B),  // an unlit panel, sampled from a powered unit
        bandInk: Color(hex: 0xE9_F0FF),
        well: Color(hex: 0x0C_0A0B),
        ink: Color(hex: 0xE7_E9EC),
        mutedInk: Color(hex: 0x91_99A1),
        rule: Color(hex: 0x34_373C),
        inert: Color(hex: 0x3A_3D42),
        warning: Color(hex: 0xF2_B33C),
        error: Color(hex: 0xFF_7B86),
        success: Color(hex: 0x4E_D092))

    static func resolved(for scheme: ColorScheme) -> Palette {
        scheme == .dark ? chroma : standard
    }
}

/// How much of a slot cell's fill the eye should see. Density is notes per step, which runs well
/// past 1, so it is clamped rather than scaled to the busiest pattern in the file: a slot means the
/// same thing in every project.
enum Density {
    static let floor = 0.18
    static let ceiling = 0.92
    /// A pattern is read as full at two notes per step; chords pass that without looking different.
    static let saturationPoint = 2.0

    static func opacity(notes: Int, steps: Int) -> Double {
        guard steps > 0, notes > 0 else { return 0 }
        let perStep = Double(notes) / Double(steps)
        let scaled = min(perStep / saturationPoint, 1)
        return floor + (ceiling - floor) * scaled
    }
}

/// The type rules. Chrome is SF Pro and every value is SF Mono, so the numbers the device shows
/// read as the device's own -- see docs/design/visual-language.md on device-true numerals.
enum TypeScale {
    static let bandTitle = Font.system(.headline, design: .default)
    static let sectionTitle = Font.system(.subheadline, design: .default).weight(.medium)
    static let label = Font.system(.caption, design: .default)
    static let smallLabel = Font.system(.caption2, design: .default)

    /// Every figure on screen: counts, step lengths, channels, limits, note names, gates.
    static let value = Font.system(.caption, design: .monospaced)
    static let smallValue = Font.system(.caption2, design: .monospaced)
    /// A row's pattern number, in its well.
    static let readout = Font.system(.caption, design: .monospaced).weight(.semibold)
}

extension Color {
    /// `0xRRGGBB`. Written as a literal so the panel values stay greppable against the manual.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }

    /// WCAG relative luminance, used only to choose an ink; the components come back in sRGB
    /// because that is the space every token above is written in.
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

    /// `self` drawn at `alpha` over `ground`, resolved to one opaque colour so
    /// ``DeviceColor/ink(on:)`` weighs what the eye sees rather than the hue alone.
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

/// Every dimension the staged view is laid out from. The window resizes freely above a floor and
/// its pane scrolls vertically only, so a row wider than ``minimumContentWidth`` is clipped at the
/// smallest window; a test holds each row under it.
enum AppLayout {
    /// The floor, not the size: the window resizes above this, and the width goes to a track name.
    /// One floor for both faces, because both draw the grid and the track list.
    static let minimumWindowWidth: CGFloat = 1020
    static let minimumWindowHeight: CGFloat = 440
    /// What a first launch opens at; afterwards the window restores the size it was left at.
    static let defaultWindowWidth: CGFloat = 1120
    static let defaultWindowHeight: CGFloat = 600
    static let sidebarWidth: CGFloat = 220
    static let dividerWidth: CGFloat = 1
    /// The band above the pane carries what the pane used to hold at its top, so the pane
    /// needs less room around it; a narrower gutter also widens ``minimumContentWidth``.
    static let mainPadding: CGFloat = 18
    /// "Show scroll bars: Always" gives the staged view's `ScrollView` a scroller that takes width.
    static let scrollerAllowance: CGFloat = 15

    static let columnCount = 16
    /// A row head, in order: the readout well, the track name, the drum badge. Summed rather than
    /// fixed, so contents that grow cannot overflow the head in silence.
    static var labelWidth: CGFloat {
        wellWidth + labelGap + rowNameWidth + labelGap + rowBadgeWidth
    }
    static let rowNameWidth: CGFloat = 68
    static let rowBadgeWidth: CGFloat = 34
    static let labelGap: CGFloat = 8
    static let cellWidth: CGFloat = 26
    static let cellSpacing: CGFloat = 3
    static let cellHeight: CGFloat = 17

    /// The source-track list a dropped MIDI file previews as, column by column.
    static let trackTickWidth: CGFloat = 18
    static let trackNumberWidth: CGFloat = 22
    /// The one column that stretches with the window; this is all it keeps at the floor.
    static let trackNameMinWidth: CGFloat = 150
    static let trackBadgeWidth: CGFloat = 78
    static let trackChannelsWidth: CGFloat = 88
    static let trackCountsWidth: CGFloat = 150
    /// "Automatic — Tracks 2, 3" is the longest a destination reads.
    static let trackDestinationWidth: CGFloat = 170
    static let trackColumnGap: CGFloat = 8

    /// The limit block's two aligned columns. "Patterns per track" is the longest name, and
    /// "192 / 192" the widest figure.
    static let limitNameWidth: CGFloat = 128
    static let limitFigureWidth: CGFloat = 62

    /// The staged pane at ``minimumWindowWidth`` -- the narrowest it gets beside the sidebar, and
    /// so the only width at which a row being clipped cannot be resized away.
    static var minimumContentWidth: CGFloat {
        minimumWindowWidth - sidebarWidth - dividerWidth - 2 * mainPadding - scrollerAllowance
    }

    /// Where the pattern axis starts, measured from a row's leading edge.
    static var gridOrigin: CGFloat { labelWidth + labelGap }

    static var gridWidth: CGFloat {
        gridOrigin + CGFloat(columnCount) * cellWidth + CGFloat(columnCount - 1) * cellSpacing
    }

    /// Every column a track row draws, in order, at the width it never goes below. A column drawn
    /// but left out of this overflows the pane in silence, which is how the destination picker did.
    static let trackColumnWidths: [CGFloat] = [
        trackTickWidth, trackNumberWidth, trackNameMinWidth, trackBadgeWidth, trackChannelsWidth,
        trackCountsWidth, trackDestinationWidth,
    ]

    static var trackRowWidth: CGFloat {
        trackColumnWidths.reduce(0, +) + CGFloat(trackColumnWidths.count - 1) * trackColumnGap
    }

    /// The leading edge of a column, 0-based, in its row's own coordinates.
    static func x(ofColumn index: Int) -> CGFloat {
        gridOrigin + CGFloat(index) * (cellWidth + cellSpacing)
    }

    /// One continuous rail under a row, in points from its leading edge.
    struct Rail: Equatable {
        let x: CGFloat
        let width: CGFloat
    }

    /// A rail spanning columns `from` through `to`, both 1-based.
    static func rail(from: Int, to: Int) -> Rail {
        let span = CGFloat(to - from + 1)
        return Rail(
            x: x(ofColumn: from - 1), width: span * cellWidth + (span - 1) * cellSpacing)
    }

    /// The rails over runs of joined columns, where `links` holds the column each join starts at.
    /// Shared so the export grid's Chain and the import grid's split cannot be drawn differently.
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

    /// The control band's height, and the well a row's pattern number sits in.
    static let bandHeight: CGFloat = 44
    static let wellWidth: CGFloat = 26
    static let wellRadius: CGFloat = 3
    static let cellRadius: CGFloat = 3
    /// The length rule under a slot cell, and the chain rail under a row.
    static let lengthRuleHeight: CGFloat = 2
    static let railHeight: CGFloat = 2
    /// The longest a Pattern runs (spec §Pattern), so the rule is a fraction of the cell rather
    /// than of the busiest pattern in the file: a length means the same thing in every project.
    static let stepCeiling = 64

    /// How much of a cell's width a pattern of `steps` claims: 6.5 / 13 / 19.5 / 26 at 16 / 32 /
    /// 48 / 64.
    static func lengthRuleWidth(steps: Int) -> CGFloat {
        guard steps > 0 else { return 0 }
        return cellWidth * CGFloat(min(steps, stepCeiling)) / CGFloat(stepCeiling)
    }
    /// One segment of a limit meter, and the gap between two.
    static let meterSegmentWidth: CGFloat = 6
    static let meterSegmentGap: CGFloat = 2
    static let meterHeight: CGFloat = 8
    static let meterSegmentCount = 24
}
