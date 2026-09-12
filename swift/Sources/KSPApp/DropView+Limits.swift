import AppKit
import KSPKit
import KSPMIDI
import KSPRun
import SwiftUI

extension DropView {
    func limits(_ limits: Limits) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            gauges(limits)

            ForEach(limits.exceeded.flatMap(\.warnings), id: \.self) { warning in
                HStack(alignment: .firstTextBaseline, spacing: AppLayout.labelGap) {
                    Image(systemName: StatusMark.error).font(.caption2)
                        .frame(width: AppLayout.findingGlyphWidth, alignment: .leading)
                        .accessibilityLabel("Error")
                    figured(warning, font: TypeScale.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(palette.error)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gauges(_ limits: Limits) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            verdictLine(limits.verdict)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(limits.gauges) { gauge in
                    HStack(spacing: AppLayout.labelGap) {
                        Text(gauge.name)
                            .font(.caption)
                            .frame(width: AppLayout.limitNameWidth, alignment: .leading)
                        meter(gauge)
                        Text(gauge.figure)
                            .font(TypeScale.value)
                            .frame(width: AppLayout.limitFigureWidth, alignment: .trailing)
                        Group {
                            if let symbol = style(gauge.status).symbol {
                                Image(systemName: symbol).font(.caption2)
                            }
                        }
                        .frame(width: AppLayout.findingGlyphWidth, alignment: .leading)
                        if let site = limits.shownSite(gauge) {
                            figured(site, font: TypeScale.label)
                                .foregroundStyle(palette.mutedInk)
                                .frame(width: AppLayout.limitSiteWidth, alignment: .leading)
                        }
                    }
                    .foregroundStyle(style(gauge.status).colour)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(gauge.name)
                    .accessibilityValue(gauge.spoken)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func meter(_ gauge: Limits.Gauge) -> some View {
        let lit = AppLayout.meterFill(used: gauge.used, limit: gauge.limit)
        return HStack(spacing: 0) {
            HStack(spacing: AppLayout.meterSegmentGap) {
                ForEach(0..<AppLayout.meterSegmentCount, id: \.self) { segment in
                    RoundedRectangle(cornerRadius: AppLayout.meterSegmentRadius)
                        .fill(segment < lit ? style(gauge.status).colour : palette.rule)
                        .frame(
                            width: AppLayout.meterSegmentWidth, height: AppLayout.meterHeight)
                }
            }
            Spacer(minLength: AppLayout.meterCapGap)
            RoundedRectangle(cornerRadius: AppLayout.meterSegmentRadius)
                .fill(palette.mutedInk)
                .frame(width: AppLayout.meterCapWidth, height: AppLayout.meterHeight)
        }
        .frame(width: AppLayout.meterWidth, alignment: .leading)
    }

    private func verdictLine(_ verdict: Limits.Verdict) -> some View {
        let mark = self.mark(verdict.status)
        return Label {
            figured(verdict.text, font: TypeScale.label)
        } icon: {
            Image(systemName: mark.symbol).font(.caption)
        }
        .foregroundStyle(mark.colour)
    }
}
