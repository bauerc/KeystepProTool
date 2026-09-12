import AppKit
import KSPKit
import KSPMIDI
import KSPRun
import SwiftUI

extension DropView {
    func restingMap(playhead: Int?) -> some View {
        VStack(alignment: .leading, spacing: AppLayout.cellSpacing) {
            ForEach(1...AppLayout.rowCount, id: \.self) { track in
                HStack(spacing: 0) {
                    rowHead(
                        readout: patternReadout(nil), name: "Track \(track)", isDrum: false,
                        dimmed: true)
                    Color.clear.frame(width: AppLayout.labelGap, height: 1)
                    HStack(spacing: AppLayout.cellSpacing) {
                        ForEach(0..<AppLayout.columnCount, id: \.self) { column in
                            restingSlot(track: track, isPlayhead: column == playhead)
                        }
                    }
                }
            }
        }
    }

    private func restingSlot(track: Int, isPlayhead: Bool) -> some View {
        let hue = DeviceColor.track(track).over(
            palette.ground, alpha: targeted ? Density.restingTargeted : Density.resting)
        return RoundedRectangle(cornerRadius: AppLayout.cellRadius)
            .fill(isPlayhead ? DeviceColor.now : hue)
            .frame(width: AppLayout.cellWidth, height: AppLayout.cellHeight)
            .overlay {
                RoundedRectangle(cornerRadius: AppLayout.cellRadius)
                    .strokeBorder(palette.rule, lineWidth: 1)
            }
    }

    var deviceCard: some View {
        let plan = model.deviceReadPlan
        return section("Read from the KeyStep Pro") {
            slotPicker

            NameField(
                prompt: DeviceRead.defaultStem(slot: model.slot), text: $model.readName,
                palette: palette)

            VStack(alignment: .leading, spacing: 2) {
                Text("Will be written to").font(TypeScale.label).foregroundStyle(palette.mutedInk)
                Text(plan.target.path).font(.callout).textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)

            if let note = plan.note {
                Text(note).font(TypeScale.label).foregroundStyle(palette.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Also write the MIDI file", isOn: $model.alsoMidi)
                    .toggleStyle(.checkbox)
                    .help("The same .mid that converting the project afterwards would make.")
                if let note = model.deviceMIDINote {
                    Text(note).font(TypeScale.label).foregroundStyle(palette.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("Read project \(model.slot)") { Task { await model.read() } }
                    .keyboardShortcut(.defaultAction)
                    .help(
                        "The device is read over USB and needs no password. A project is read "
                            + "as it was saved, so save any panel edits first.")
            }
        }
        .frame(width: AppLayout.deviceCardWidth, alignment: .leading)
    }

    private var slotPicker: some View {
        HStack(spacing: AppLayout.cellSpacing) {
            ForEach(Array(DeviceRead.slots), id: \.self) { slot in slotCell(slot) }
        }
        .frame(width: AppLayout.slotPickerWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project slots")
    }

    private func slotCell(_ slot: Int) -> some View {
        let chosen = slot == model.slot
        return Button {
            model.slot = slot
        } label: {
            Text(patternReadout(slot))
                .font(TypeScale.readout)
                .foregroundStyle(chosen ? palette.wellInk : palette.mutedInk)
                .frame(width: AppLayout.cellWidth, height: AppLayout.slotCellHeight)
                .background(
                    RoundedRectangle(cornerRadius: AppLayout.cellRadius)
                        .fill(chosen ? palette.well : palette.inert)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AppLayout.cellRadius)
                        .strokeBorder(palette.ink.opacity(chosen ? 0.55 : 0), lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Project \(slot)")
        .accessibilityLabel("Project \(slot)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    var reading: some View {
        VStack(spacing: 8) {
            ProgressView("Reading from the KeyStep Pro…")
            Text("Leave the device alone until it finishes.")
                .font(TypeScale.label).foregroundStyle(palette.mutedInk)
        }
    }
}
