import AppKit
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

    /// Worn by the application, not by the window: a window's own appearance dresses what SwiftUI
    /// draws and leaves the title bar, the toolbar and the folder chooser on the system's face.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .standard: return NSAppearance(named: .aqua)
        case .chroma: return NSAppearance(named: .darkAqua)
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
    /// A recessed panel the pattern map and the meters sit in, and a well with nothing to read out.
    let surface: Color
    /// The lit well behind a row's pattern number, after the four 7-segment displays.
    let well: Color
    /// The digits in a lit ``well``.
    let wellInk: Color
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
    /// How much of its track's hue a held arrange-lane region wears over ``ground``. Per face, not
    /// shared: the Chroma's wash over the standard ground is a pastel that no longer reads as a hue.
    let laneWash: Double

    /// The standard unit: an off-white metal wedge with a matte black control band.
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

    /// The Chroma: a dark grey shell with icy blue indicators.
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

/// How much of a slot cell's fill the eye should see. Density is notes per step, which runs well
/// past 1, so it is clamped rather than scaled to the busiest pattern in the file: a slot means the
/// same thing in every project.
enum Density {
    static let floor = 0.18
    static let ceiling = 0.92
    /// The map at rest, held under ``floor`` so an empty map can never read as one holding notes.
    static let resting = 0.14
    /// The same map under a file being dragged over the window. The instrument lighting up is the
    /// drop target: a wash over the pane would sit on a ground the map has already coloured.
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

/// The type rules. Chrome is SF Pro and every value is SF Mono, so the numbers the device shows
/// read as the device's own -- see docs/design/visual-language.md on device-true numerals.
enum TypeScale {
    static let header = Font.system(.title2, design: .default).weight(.semibold)
    static let sectionTitle = Font.system(.title3, design: .default).weight(.semibold)
    static let label = Font.system(.callout, design: .default)
    static let smallLabel = Font.system(.caption2, design: .default)
    /// The status glyph a finished run leads with, set above everything it heads.
    static let resultMark = Font.system(.largeTitle)

    /// Every figure on screen: counts, step lengths, channels, limits, note names, gates.
    /// The figure sizes hold while ``AppLayout`` fixes a slot cell at 26x17: they set its content.
    static let value = Font.system(.caption, design: .monospaced)
    static let smallValue = Font.system(.caption2, design: .monospaced)
    /// A row's pattern number, in its well.
    static let readout = Font.system(.caption, design: .monospaced).weight(.semibold)
    /// A figure inside a headline, which is set a size above the rest of the chrome.
    static let headlineValue = Font.system(.callout, design: .monospaced)
}

/// The SF Symbols status is marked with. Rule 2 of the visual language turns on the glyph rather
/// than the hue, so a limit gauge, a finding row and the done band read from one vocabulary.
enum StatusMark {
    static let warning = "exclamationmark.circle"
    static let error = "exclamationmark.triangle"
    static let success = "checkmark.circle"
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
    /// The idle pane is the one that does not scroll -- the map, then the device card under it --
    /// so it is what the floor has to clear.
    static let minimumWindowHeight: CGFloat = 640
    /// What a first launch opens at; afterwards the window restores the size it was left at.
    static let defaultWindowWidth: CGFloat = 1120
    static let defaultWindowHeight: CGFloat = 700
    /// A narrower gutter widens ``minimumContentWidth``.
    static let mainPadding: CGFloat = 18
    /// "Show scroll bars: Always" gives the staged view's `ScrollView` a scroller that takes width.
    static let scrollerAllowance: CGFloat = 15

    static let columnCount = 16
    /// The four sequencer tracks the map is rows of, one panel colour each (manual §1.4).
    static let rowCount = 4
    /// A row head, in order: the readout well, the track name, the drum badge. Summed rather than
    /// fixed, so contents that grow cannot overflow the head in silence.
    static var labelWidth: CGFloat {
        wellWidth + labelGap + rowNameWidth + labelGap + rowBadgeWidth
    }
    static let rowNameWidth: CGFloat = 68
    /// "Drum" and its capsule padding; at 34 the word truncated to "Dr...".
    static let rowBadgeWidth: CGFloat = 44
    static let labelGap: CGFloat = 8
    /// The map is the widest thing the pane draws, so it is the cell that sets
    /// ``minimumWindowWidth`` rather than the window that leaves the cell what is spare.
    static let cellWidth: CGFloat = 46
    static let cellSpacing: CGFloat = 3
    static let cellHeight: CGFloat = 26

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

    /// The staged pane at ``minimumWindowWidth`` -- the narrowest it gets, and so the only width
    /// at which a row being clipped cannot be resized away.
    static var minimumContentWidth: CGFloat {
        minimumWindowWidth - 2 * mainPadding - scrollerAllowance
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

    /// The action bar under the pane. Fixed, so a phase carrying no action leaves the chassis
    /// standing rather than dropping the window's foot out.
    static let actionBarHeight: CGFloat = 56
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
    /// The arrange lanes, on the map's own origin so a lane sits under the row it belongs to. The
    /// whole run scales into this, which is what keeps the pane scrolling vertically only.
    static var axisWidth: CGFloat { gridWidth - gridOrigin }
    /// Tall enough for an octave's twelve pitches to stand apart. A note shape is drawn to it too.
    static let laneHeight: CGFloat = 56
    static let laneSpacing: CGFloat = 3
    static let regionRadius: CGFloat = 3
    static let boundaryWidth: CGFloat = 1
    static let markHeight: CGFloat = 3
    /// A sixteenth at the default division is under a point wide once a long run is scaled down.
    static let markMinWidth: CGFloat = 1.5
    /// The block's ink, held off full so a mark reads as content rather than as lettering.
    static let markInkOpacity = 0.75
    /// Narrower than this a region holds fewer points than it has events, where a sketch is noise
    /// rather than rhythm; the block still carries the length.
    static let marksMinimumWidth: CGFloat = 14
    /// A single digit at ``TypeScale/smallValue``, which is the narrowest a number stays a number.
    static let regionLabelMinimumWidth: CGFloat = 11
    static let regionLabelInset: CGFloat = 2
    /// The narrowest range a shape is drawn across, so one held pitch sits mid-lane and a fifth
    /// does not fill it the way two octaves would.
    static let pitchWindowMinimumSpan = 12
    /// Closer than this, grid lines are a texture rather than a grid.
    static let gridLineMinimumSpacing: CGFloat = 8
    /// Fainter than a mark: a grid line is where a note on the grid would start, not a note. The
    /// accent opening each group is what the eye counts a run by, so it is the heavier of the two.
    static let gridInkOpacity = 0.14
    static let gridAccentInkOpacity = 0.5
    static let gridAccentWidth: CGFloat = 1.5
    /// The export writes 4/4, so its bar is four beats.
    static let beatsPerBar = 4
    static let middleCInkOpacity = 0.45
    /// "C#-1" is the longest a pitch reads.
    static let pitchLabelWidth: CGFloat = 30
    static let pitchLabelHeight: CGFloat = 12
    /// What the map's row head leaves beside the pitch labels, for the track a shape is of.
    static var shapeHeadWidth: CGFloat { gridOrigin - labelGap - pitchLabelWidth }
    /// The bracket under a note shape saying which Pattern each stretch of it becomes.
    static let bracketHeight: CGFloat = 14
    static let bracketTickHeight: CGFloat = 5
    /// "pattern 16 · 64 steps" at ``TypeScale/smallValue``, and the rule either side of it.
    static let bracketLabelMinimumWidth: CGFloat = 150
    /// A slot cell's picture of its own Pattern, inset clear of the corners and the length rule.
    static let thumbnailInset: CGFloat = 3
    static let thumbnailMarkHeight: CGFloat = 1.5

    /// Where a tick falls on the axis, and how wide a run of ticks draws. A run of no length
    /// scales nothing, so the whole axis is left empty rather than divided by zero.
    static func x(ofTick tick: Int, in totalTicks: Int) -> CGFloat {
        guard totalTicks > 0 else { return 0 }
        return axisWidth * CGFloat(tick) / CGFloat(totalTicks)
    }

    static func width(ofTicks ticks: Int, in totalTicks: Int) -> CGFloat {
        guard totalTicks > 0, ticks > 0 else { return 0 }
        return axisWidth * CGFloat(min(ticks, totalTicks)) / CGFloat(totalTicks)
    }

    /// How many units apart the lines fall: every unit, else every `group` of them, else every
    /// group of groups -- the first that leaves ``gridLineMinimumSpacing``. None where a unit has
    /// no width.
    static func gridStride(unitWidth: CGFloat, group: Int) -> Int {
        guard unitWidth > 0 else { return 0 }
        let factor = max(group, 2)
        var stride = 1
        while CGFloat(stride) * unitWidth < gridLineMinimumSpacing { stride *= factor }
        return stride
    }

    /// One segment of a limit meter, and the gap between two.
    static let meterSegmentWidth: CGFloat = 6
    static let meterSegmentGap: CGFloat = 2
    static let meterHeight: CGFloat = 8
    static let meterSegmentCount = 24
    static let meterSegmentRadius: CGFloat = 1
    /// The ceiling the segments fill toward, and the space held clear before it.
    static let meterCapWidth: CGFloat = 1.5
    static let meterCapGap: CGFloat = 3

    /// Summed rather than fixed, for the reason ``labelWidth`` is.
    static var meterWidth: CGFloat {
        CGFloat(meterSegmentCount) * meterSegmentWidth
            + CGFloat(meterSegmentCount - 1) * meterSegmentGap + meterCapGap + meterCapWidth
    }

    /// How many segments are lit. Pure quantity: any figure at all lights one, the limit and
    /// anything past it lights them all, and nothing between the two skips backwards. The last
    /// segment is the wall itself, so a figure short of it never fills the meter -- rounding to
    /// nearest would light 63 of 64 steps as full and leave the meter saying nothing.
    static func meterFill(used: Int, limit: Int) -> Int {
        guard used > 0, limit > 0 else { return 0 }
        guard used < limit else { return meterSegmentCount }
        let lit = (Double(used) / Double(limit) * Double(meterSegmentCount)).rounded()
        return min(meterSegmentCount - 1, max(1, Int(lit)))
    }

    /// The slot picker sits on the pattern map's own column metrics, so a project number stands
    /// where a pattern number does. Taller than a slot cell only because this one is clicked.
    static var slotPickerWidth: CGFloat { axisWidth }
    static let slotCellHeight: CGFloat = 24
    /// The device card, which the idle pane holds beside nothing else, so it is sized to its own
    /// contents rather than to the pane.
    static let deviceCardWidth: CGFloat = 820
    /// The settings window, which holds nothing wider than a folder path and is sized to read one.
    static let settingsWidth: CGFloat = 460
    /// A rule between two groups in the action bar, kept under the bar's own height.
    static let footerDividerHeight: CGFloat = 24
    /// The option band under a source, and the rule that separates its two groups.
    static let bandPadding: CGFloat = 8
    static let bandDividerHeight: CGFloat = 18
    static let bandGap: CGFloat = 12
    /// Every control an option band draws, at the width it is held to. Fixed rather than left to
    /// AppKit for the reason ``trackColumnWidths`` is: the band is one row inside a pane that
    /// scrolls vertically only, so a control that outgrows it is clipped in silence.
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
        widths.reduce(0, +) + CGFloat(widths.count - 1) * bandGap + 2 * (bandPadding + 2)
    }
    static let deviceCardPadding: CGFloat = 14
    static let cardRadius: CGFloat = 8

    /// A name field, drawn rather than bezelled. Tighter than a card, because a field sits inside
    /// one, and the ring is heavy enough to read against a fill only a hairline separates from the
    /// ground.
    static let fieldRadius: CGFloat = 5
    static let fieldPadding = EdgeInsets(top: 5, leading: 7, bottom: 5, trailing: 7)
    static let fieldRingWidth: CGFloat = 3
    /// A tickable cell under the pointer: lighter than a field's ring, with sixteen side by side.
    static let hoverRingWidth: CGFloat = 1.5
    static let pressedOpacity: Double = 0.6

    /// A severity glyph's column, wide enough that the text beside it starts on one edge.
    static let findingGlyphWidth: CGFloat = 14
    /// "Track 1, pattern 16" is the longest a gauge's site reads.
    static let limitSiteWidth: CGFloat = 150

    /// Every fixed column of a limit row, for the reason ``trackRowWidth`` sums its own.
    static var limitRowWidth: CGFloat {
        limitNameWidth + meterWidth + limitFigureWidth + findingGlyphWidth + limitSiteWidth
            + 4 * labelGap
    }
}
