import AppKit
import KSPKit
import KSPMIDI
import KSPRun
import SwiftUI

extension DropView {
    func grid(_ grid: PatternGrid, selection: GridSelection?, length: ExportLength?)
        -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            Text(grid.header).font(TypeScale.label).foregroundStyle(palette.mutedInk)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: AppLayout.gridOrigin, height: 1)
                    HStack(spacing: AppLayout.cellSpacing) {
                        ForEach(grid.columns, id: \.self) { column in
                            columnHeader(column, selection: selection)
                        }
                    }
                }
                ForEach(grid.rows, id: \.track) { trackRow($0, selection: selection) }
            }

            if let warning = length?.warning {
                Text(warning).font(TypeScale.label).foregroundStyle(palette.mutedInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func tickable<Label: View>(
        _ label: Label, named name: String, value: String, help: String,
        toggle: (() -> Void)?
    ) -> some View {
        if let toggle {
            Button(action: toggle) {
                label.contentShape(Rectangle())
            }
            .buttonStyle(TickStyle())
            .help(help)
            .accessibilityLabel(name)
            .accessibilityValue(value)
        } else {
            label.help(help)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(name)
                .accessibilityValue(value)
        }
    }

    private func columnHeader(_ column: Int, selection: GridSelection?) -> some View {
        let state = selection?.state(ofPattern: column) ?? .on
        let toggle: (() -> Void)? =
            selection == nil ? nil : { model.toggle(pattern: column) }
        let help =
            toggle == nil
            ? "Pattern slot \(column)"
            : (state == .on
                ? "Pattern slot \(column) — click to untick it on every track."
                : "Pattern slot \(column) — click to tick it on every track.")
        return tickable(
            columnLabel(column, state: state), named: "Pattern slot \(column)",
            value: state.spoken, help: help, toggle: toggle
        )
        .accessibilityHidden(toggle == nil)
    }

    private func columnLabel(_ column: Int, state: GridSelection.Tick) -> some View {
        Text("\(column)")
            .font(TypeScale.smallValue)
            .foregroundStyle(state == .on ? HierarchicalShapeStyle.secondary : .tertiary)
            .strikethrough(state == .off)
            .frame(width: AppLayout.cellWidth)
    }

    private func trackRow(_ row: PatternGrid.Row, selection: GridSelection?) -> some View {
        let state = selection?.state(ofTrack: row.track) ?? .on
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                trackHead(row, state: state, ticking: selection != nil)
                Color.clear.frame(width: AppLayout.labelGap, height: 1)
                HStack(spacing: AppLayout.cellSpacing) {
                    ForEach(row.cells, id: \.pattern) {
                        slot($0, track: row.track, selection: selection)
                    }
                }
            }
            .padding(.bottom, 4)
            .overlay(alignment: .bottomLeading) { rails(row.runs, track: row.track) }

            if let chain = row.chainDetail {
                Text(chain)
                    .font(TypeScale.smallValue).foregroundStyle(palette.mutedInk)
                    .padding(.leading, AppLayout.gridOrigin)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.name), \(row.spoken)")
    }

    private func trackHead(_ row: PatternGrid.Row, state: GridSelection.Tick, ticking: Bool)
        -> some View
    {
        let head = rowHead(
            readout: row.readout, name: row.name, isDrum: row.isDrum, struck: state == .off,
            dimmed: state != .on)
        let help =
            ticking
            ? row.detail
                + (state == .on
                    ? " · Click to untick this whole track."
                    : " · Click to tick this whole track.")
            : row.detail
        return tickable(
            head, named: row.name, value: state.spoken, help: help,
            toggle: ticking ? { model.toggle(track: row.track) } : nil
        )
        .accessibilityHidden(!ticking)
    }

    func rails(_ runs: [AppLayout.Rail], track: Int) -> some View {
        let color = DeviceColor.track(track)
        return ForEach(runs.indices, id: \.self) { index in
            Capsule()
                .fill(color)
                .frame(width: runs[index].width, height: AppLayout.railHeight)
                .offset(x: runs[index].x)
        }
    }

    func slotFill(track: Int, notes: Int, steps: Int, isEmpty: Bool) -> Color {
        guard !isEmpty else { return palette.inert }
        let density = max(Density.opacity(notes: notes, steps: steps), Density.floor)
        return DeviceColor.track(track).over(palette.ground, alpha: density)
    }

    func slotBackground(fill: Color, ink: Color, steps: Int) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: AppLayout.cellRadius).fill(fill)
            Rectangle()
                .fill(ink)
                .frame(
                    width: AppLayout.lengthRuleWidth(steps: steps),
                    height: AppLayout.lengthRuleHeight)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppLayout.cellRadius))
    }

    /// An em dash means the slot holds nothing; `0` means it holds notes with every step off.
    func slot(_ cell: PatternGrid.Cell, track: Int, selection: GridSelection?) -> some View {
        let ticked = selection?.isTicked(track: track, pattern: cell.pattern) ?? true
        let toggle: (() -> Void)? =
            selection == nil ? nil : { model.toggle(track: track, pattern: cell.pattern) }
        let help =
            toggle == nil
            ? cell.detail
            : cell.detail + (ticked ? "" : " · unticked, so it will not be exported")
        let value =
            toggle == nil
            ? cell.spoken
            : "\(cell.spoken), \((ticked ? GridSelection.Tick.on : .off).spoken)"
        return tickable(
            slotFace(cell, track: track, ticked: ticked), named: "Pattern \(cell.pattern)",
            value: value, help: help, toggle: toggle)
    }

    private func slotFace(_ cell: PatternGrid.Cell, track: Int, ticked: Bool) -> some View {
        let fill = slotFill(
            track: track, notes: cell.noteCount, steps: cell.stepCount, isEmpty: cell.isEmpty)
        let ink = DeviceColor.ink(on: fill)
        return Text(cell.label)
            .font(TypeScale.value)
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(cell.isEmpty ? palette.mutedInk : ink)
            .frame(width: AppLayout.cellWidth, height: AppLayout.cellHeight)
            .background(
                slotBackground(
                    fill: fill, ink: ink, steps: cell.isEmpty ? 0 : cell.stepCount)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppLayout.cellRadius)
                    .strokeBorder(
                        ink.opacity(0.35),
                        style: ticked
                            ? StrokeStyle(lineWidth: 1)
                            : StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
    }

    func rowHead(
        readout: String, name: String, isDrum: Bool, struck: Bool = false, dimmed: Bool = false
    ) -> some View {
        let lit = readout != patternReadout(nil)
        return HStack(spacing: AppLayout.labelGap) {
            Text(readout)
                .font(TypeScale.readout).foregroundStyle(lit ? palette.wellInk : palette.mutedInk)
                .frame(width: AppLayout.wellWidth, height: AppLayout.cellHeight)
                .background(
                    RoundedRectangle(cornerRadius: AppLayout.wellRadius)
                        .fill(lit ? palette.well : palette.surface)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AppLayout.wellRadius)
                        .strokeBorder(palette.rule.opacity(lit ? 0 : 1), lineWidth: 1)
                }
            Text(name)
                .font(.caption).fontWeight(.medium).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(dimmed ? palette.mutedInk : palette.ink)
                .strikethrough(struck)
                .frame(width: AppLayout.rowNameWidth, alignment: .leading)
            Group {
                if isDrum {
                    Text("Drum")
                        .font(TypeScale.smallLabel).lineLimit(1)
                        .foregroundStyle(palette.mutedInk)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(palette.inert))
                }
            }
            .frame(width: AppLayout.rowBadgeWidth, alignment: .leading)
        }
        .frame(width: AppLayout.labelWidth, alignment: .leading)
    }
}
