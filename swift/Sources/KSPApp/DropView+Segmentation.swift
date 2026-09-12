import AppKit
import KSPKit
import KSPMIDI
import KSPRun
import SwiftUI

/// A pattern too long for one slot, drawn across the slots it was split into.
extension DropView {
    /// Read-only, and redrawn whenever the ticks or a setting move it: what the planner says the
    /// import would lay down, rather than what the file holds.
    @ViewBuilder
    func segmentation(_ state: SegmentationState) -> some View {
        switch state {
        case .loading:
            section("Result") { ProgressView("Planning the import…").controlSize(.small) }
        case .failed(let message):
            section("Result") {
                // Not drawn as an exceeded limit: an unreadable file and a single-target import
                // fail the same way, and only the planner's own words say which of the three.
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(TypeScale.label).foregroundStyle(palette.warning).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .ready(let plan):
            VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                section("Result") {
                    segmentationGrid(SegmentationGrid(plan.summary))
                    noteShapes(NoteShape.shapes(plan.summary))
                }
                section(Limits.heading) {
                    limits(Limits(plan.summary))
                    findingList(
                        plan.rows(verbose: model.verbose), count: plan.allRows.count)
                }
            }
        }
    }

    private func segmentationGrid(_ grid: SegmentationGrid) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(grid.header).font(TypeScale.label).foregroundStyle(palette.mutedInk)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: AppLayout.gridOrigin, height: 1)
                    HStack(spacing: AppLayout.cellSpacing) {
                        ForEach(grid.columns, id: \.self) { column in
                            Text("\(column)")
                                .font(TypeScale.smallValue).foregroundStyle(.tertiary)
                                .frame(width: AppLayout.cellWidth)
                        }
                    }
                }
                // Each cell names its own slot, so a figure over it would say it twice.
                .accessibilityHidden(true)
                ForEach(grid.rows, id: \.track) { segmentationRow($0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func segmentationRow(_ row: SegmentationGrid.Row) -> some View {
        HStack(spacing: 0) {
            rowHead(
                readout: row.readout, name: row.name, isDrum: row.isDrum, dimmed: row.isEmpty
            )
            .help(row.detail)
            .accessibilityHidden(true)
            Color.clear.frame(width: AppLayout.labelGap, height: 1)
            HStack(spacing: AppLayout.cellSpacing) {
                ForEach(row.cells, id: \.pattern) { segmentationSlot($0, track: row.track) }
            }
        }
        .padding(.bottom, 4)
        // Under the cells for the reason the Chain rail is: a rail behind them would band.
        .overlay(alignment: .bottomLeading) { rails(row.runs, track: row.track) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.name), \(row.spoken)")
    }

    private func segmentationSlot(_ cell: SegmentationGrid.Cell, track: Int) -> some View {
        let fill = slotFill(
            track: track, notes: cell.noteCount, steps: cell.stepCount, isEmpty: cell.isEmpty)
        let ink = DeviceColor.ink(on: fill)
        return ZStack {
            noteMarks(
                cell.thumbnail, height: AppLayout.thumbnailMarkHeight,
                colour: ink.opacity(AppLayout.markInkOpacity))
            if let label = cell.label {
                Text(label).font(TypeScale.smallValue).foregroundStyle(palette.mutedInk)
            }
        }
        .frame(width: AppLayout.cellWidth, height: AppLayout.cellHeight)
        .background(slotBackground(fill: fill, ink: ink, steps: cell.stepCount))
        .help(cell.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pattern \(cell.pattern)")
        .accessibilityValue(cell.spoken)
    }

    private func noteShapes(_ shapes: [NoteShape]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shapes, id: \.track) { noteShape($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The pitch labels stand where the map's drum badge does, so the shape starts on the map's
    /// own origin and its steps line up under the columns they become.
    private func noteShape(_ shape: NoteShape) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shape.name).font(.caption).fontWeight(.medium).foregroundStyle(palette.ink)
                if let range = shape.range {
                    Text(range).font(TypeScale.smallValue).foregroundStyle(palette.mutedInk)
                }
            }
            .frame(width: AppLayout.shapeHeadWidth, alignment: .leading)
            .help(shape.detail)
            ZStack(alignment: .topTrailing) {
                ForEach(shape.labels, id: \.text) { label in
                    Text(label.text)
                        .font(TypeScale.smallValue).foregroundStyle(palette.mutedInk)
                        .frame(height: AppLayout.pitchLabelHeight)
                        .offset(y: label.y)
                }
            }
            .frame(
                width: AppLayout.pitchLabelWidth, height: AppLayout.laneHeight,
                alignment: .topTrailing)
            Color.clear.frame(width: AppLayout.labelGap, height: 1)
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(palette.ground)
                    ForEach(shape.regions, id: \.pattern) { region in
                        noteBlock(
                            track: shape.track, isEmpty: region.isEmpty, marks: region.marks,
                            grid: region.grid, middleC: shape.middleC
                        )
                        .frame(width: region.width, height: AppLayout.laneHeight)
                        .offset(x: region.x)
                    }
                    ForEach(shape.regions.dropFirst(), id: \.pattern) { region in
                        Rectangle()
                            .fill(palette.rule)
                            .frame(width: AppLayout.boundaryWidth, height: AppLayout.laneHeight)
                            .offset(x: region.x)
                    }
                }
                .frame(
                    width: AppLayout.axisWidth, height: AppLayout.laneHeight, alignment: .topLeading
                )
                .clipped()
                ZStack(alignment: .topLeading) {
                    ForEach(shape.regions, id: \.pattern) { bracket($0) }
                }
                .frame(
                    width: AppLayout.axisWidth, height: AppLayout.bracketHeight,
                    alignment: .topLeading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shape.name)
        .accessibilityValue(shape.spoken)
    }

    /// Ticked at both ends, so two Patterns side by side cannot read as one.
    private func bracket(_ region: NoteShape.Region) -> some View {
        let tick = Rectangle().fill(palette.rule)
            .frame(width: 1, height: AppLayout.bracketTickHeight)
        return HStack(spacing: 4) {
            Rectangle().fill(palette.rule).frame(height: 1)
            if region.showsBracket {
                Text(region.bracket)
                    .font(TypeScale.smallValue).foregroundStyle(palette.mutedInk)
                    .lineLimit(1).fixedSize()
                Rectangle().fill(palette.rule).frame(height: 1)
            }
        }
        .overlay(alignment: .leading) { tick }
        .overlay(alignment: .trailing) { tick }
        .padding(.horizontal, 1)
        .frame(width: region.width, height: AppLayout.bracketHeight)
        .offset(x: region.x)
        .help(region.bracket)
    }

    /// Where the planner put each source track, for the pickers to show as their automatic answer.
    /// Empty while a plan is in flight, which leaves a picker reading "Automatic" on its own.
    func placements(_ state: SegmentationState) -> [Int: String] {
        guard case .ready(let plan) = state else { return [:] }
        return SegmentationGrid.placements(plan.summary)
    }
}
