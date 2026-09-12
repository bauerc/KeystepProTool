import AppKit
import KSPKit
import KSPMIDI
import KSPRun
import SwiftUI

/// How a status is worded and marked, shared by every pane that reports one.
extension DropView {
    func mark(_ status: Limits.Status) -> (colour: Color, symbol: String) {
        switch status {
        case .within: return (palette.success, StatusMark.success)
        case .near: return (palette.warning, StatusMark.warning)
        case .over: return (palette.error, StatusMark.error)
        }
    }

    /// A refusal is the only one of the three marked: the meter already says how close a figure
    /// sits, so approaching a wall is emphasis on a quantity rather than a status. Passing one is
    /// a status, and it takes the colour and the glyph together -- rule 2.
    func style(_ status: Limits.Status) -> (colour: Color, symbol: String?) {
        switch status {
        case .within: return (palette.ink, nil)
        case .near: return (palette.warning, nil)
        case .over: return (palette.error, StatusMark.error)
        }
    }

    /// Rule 2 again, on a finding rather than a gauge: the glyph and the order carry severity and
    /// the colour only agrees with them.
    func style(_ severity: Severity) -> (colour: Color, symbol: String) {
        severity == .error
            ? (palette.error, StatusMark.error) : (palette.warning, StatusMark.warning)
    }

    /// A failure line names the file that failed, and a filename's digits are not figures: the
    /// `2` of `Take2.wav` is part of a name, not a value the device shows.
    @ViewBuilder
    func headline(_ outcome: Outcome, font: Font, figures: Font) -> some View {
        if outcome.failed {
            Text(outcome.headline).font(font)
        } else {
            figured(outcome.headline, font: font, figures: figures)
        }
    }

    /// Rule 3, applied to prose the core wrote: every figure in it set in SF Mono. Concatenated
    /// rather than laid out, so the line still wraps and still selects as one piece of text.
    func figured(_ text: String, font: Font, figures: Font = TypeScale.value) -> Text {
        Figures.split(text).reduce(Text(verbatim: "")) { built, run in
            built + Text(run.text).font(run.isFigure ? figures : font)
        }
    }
}
