import AppKit
import KSPKit
import KSPMIDI
import KSPRun
import SwiftUI

extension DropView {
    @ViewBuilder
    func arrangement(_ state: ArrangementState) -> some View {
        switch state {
        case .loading:
            ProgressView("Laying out the patterns…").controlSize(.small)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(TypeScale.label).foregroundStyle(palette.warning).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .ready(let summary):
            lanes(ArrangeLanes(summary))
        }
    }

    private func lanes(_ lanes: ArrangeLanes) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lanes.header).font(TypeScale.label).foregroundStyle(palette.mutedInk)

            VStack(alignment: .leading, spacing: AppLayout.laneSpacing) {
                ForEach(lanes.lanes, id: \.track) { lane($0, boundaries: lanes.boundaries) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lane(_ lane: ArrangeLanes.Lane, boundaries: [ArrangeLanes.Boundary]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                rowHead(
                    readout: lane.readout, name: lane.name, isDrum: lane.isDrum,
                    dimmed: lane.isEmpty)
                if let range = lane.range {
                    Text(range)
                        .font(TypeScale.smallValue).foregroundStyle(palette.mutedInk)
                        .padding(.leading, AppLayout.wellWidth + AppLayout.labelGap)
                }
            }
            .help(lane.detail)
            .accessibilityHidden(true)
            Color.clear.frame(width: AppLayout.labelGap, height: 1)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(palette.ground)
                ForEach(lane.regions, id: \.slot) {
                    region($0, track: lane.track, middleC: lane.middleC)
                }
                ForEach(boundaries, id: \.slot) { boundary in
                    Rectangle()
                        .fill(palette.rule)
                        .frame(width: AppLayout.boundaryWidth, height: AppLayout.laneHeight)
                        .offset(x: boundary.x)
                }
            }
            .frame(width: AppLayout.axisWidth, height: AppLayout.laneHeight, alignment: .topLeading)
            .clipped()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(lane.name), \(lane.spoken)")
    }

    func region(_ region: ArrangeLanes.Region, track: Int, middleC: CGFloat?) -> some View {
        let ink = DeviceColor.ink(on: blockFill(track: track, isEmpty: region.isEmpty))
        return noteBlock(
            track: track, isEmpty: region.isEmpty, marks: region.showsMarks ? region.marks : [],
            grid: region.grid, middleC: region.showsMarks ? middleC : nil
        )
        .overlay(alignment: .topLeading) {
            if region.showsLabel {
                Text(region.label)
                    .font(TypeScale.smallValue)
                    .foregroundStyle(region.isEmpty ? palette.mutedInk : ink)
                    .padding(.leading, AppLayout.regionLabelInset)
            }
        }
        .frame(width: region.width, height: AppLayout.laneHeight, alignment: .topLeading)
        .clipped()
        .offset(x: region.x)
        .help(region.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pattern \(region.pattern)")
        .accessibilityValue(region.spoken)
    }

    func noteBlock(
        track: Int, isEmpty: Bool, marks: [NoteMark], grid: [GridLine], middleC: CGFloat?
    ) -> some View {
        let fill = blockFill(track: track, isEmpty: isEmpty)
        let ink = DeviceColor.ink(on: fill)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: AppLayout.regionRadius).fill(fill)
            drawGrid(grid, ink: ink)
            if let middleC {
                Rectangle()
                    .fill(ink.opacity(AppLayout.middleCInkOpacity))
                    .frame(height: 1)
                    .offset(y: middleC - 0.5)
            }
            noteMarks(
                marks, height: AppLayout.markHeight, colour: ink.opacity(AppLayout.markInkOpacity))
        }
    }

    private func blockFill(track: Int, isEmpty: Bool) -> Color {
        isEmpty
            ? palette.inert : DeviceColor.track(track).over(palette.ground, alpha: palette.laneWash)
    }

    func noteMarks(_ marks: [NoteMark], height: CGFloat, colour: Color) -> some View {
        Canvas { context, _ in
            for mark in marks {
                context.fill(
                    Path(CGRect(x: mark.x, y: mark.y, width: mark.width, height: height)),
                    with: .color(colour))
            }
        }
    }

    private func drawGrid(_ lines: [GridLine], ink: Color) -> some View {
        Canvas { context, size in
            for line in lines {
                let width = line.accented ? AppLayout.gridAccentWidth : 1
                let opacity =
                    line.accented ? AppLayout.gridAccentInkOpacity : AppLayout.gridInkOpacity
                context.fill(
                    Path(
                        CGRect(
                            x: line.x + (1 - width) / 2, y: 0, width: width, height: size.height)),
                    with: .color(ink.opacity(opacity)))
            }
        }
    }
}
