import AppKit
import KSPKit
import KSPMIDI
import KSPRun
import SwiftUI

/// Reading a project off the hardware: the card, the slot picker, and the map at rest.
extension DropView {
    /// Idle and converting are one object: the empty map in the track colours, at an intensity
    /// under anything a slot holding notes takes. `playhead` lights a column white, which is what
    /// the device lights the step it is playing.
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

    /// The rule around every cell is what draws the map while it holds nothing, and what keeps
    /// the white step legible on the standard unit's off-white ground.
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

    /// The other way a project reaches the app: off the device rather than out of a file. It sits
    /// on the idle pane because it is an alternative to the drop above it, not a mode of its own.
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

    /// The device's sixteen on the pattern map's own metrics. The chosen one is a lit readout
    /// among unlit ones and the Read button names it, so no hue carries the choice.
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

    /// The walk reports no position, so the progress is the system's own indeterminate view --
    /// with the one instruction that matters while it runs.
    var reading: some View {
        VStack(spacing: 8) {
            ProgressView("Reading from the KeyStep Pro…")
            Text("Leave the device alone until it finishes.")
                .font(TypeScale.label).foregroundStyle(palette.mutedInk)
        }
    }
}
