import AppKit
import KSPKit
import KSPMIDI
import KSPRun
import SwiftUI

extension DropView {
    func mark(_ status: Limits.Status) -> (colour: Color, symbol: String) {
        switch status {
        case .within: return (palette.success, StatusMark.success)
        case .near: return (palette.warning, StatusMark.warning)
        case .over: return (palette.error, StatusMark.error)
        }
    }

    func style(_ status: Limits.Status) -> (colour: Color, symbol: String?) {
        switch status {
        case .within: return (palette.ink, nil)
        case .near: return (palette.warning, nil)
        case .over: return (palette.error, StatusMark.error)
        }
    }

    func style(_ severity: Severity) -> (colour: Color, symbol: String) {
        severity == .error
            ? (palette.error, StatusMark.error) : (palette.warning, StatusMark.warning)
    }

    @ViewBuilder
    func headline(_ outcome: Outcome, font: Font, figures: Font) -> some View {
        if outcome.failed {
            Text(outcome.headline).font(font)
        } else {
            figured(outcome.headline, font: font, figures: figures)
        }
    }

    func figured(_ text: String, font: Font, figures: Font = TypeScale.value) -> Text {
        Figures.split(text).reduce(Text(verbatim: "")) { built, run in
            built + Text(run.text).font(run.isFigure ? figures : font)
        }
    }
}
