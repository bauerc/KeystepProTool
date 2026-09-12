import AppKit
import KSPKit
import KSPMIDI
import KSPRun
import SwiftUI

/// A dropped MIDI file's source tracks and where each one is routed.
extension DropView {
    /// Unscrolled, like ``grid(_:selection:length:)``: the staged view already scrolls.
    func trackList(
        _ list: SourceTrackList, selection: SourceTrackSelection, placements: [Int: String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(list.header).font(TypeScale.label).foregroundStyle(palette.mutedInk)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(list.rows, id: \.number) {
                    trackRow(
                        $0, ticked: selection.isTicked($0.number),
                        destination: selection.destination($0.number),
                        placement: placements[$0.number])
                }
            }

            // Ticking past the device's four is flagged, not refused, so Convert stays enabled.
            if let overflow = selection.overflowNote {
                Label(overflow, systemImage: "exclamationmark.triangle")
                    .font(TypeScale.label).foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = list.note(verbose: model.verbose) {
                Text(note).font(TypeScale.label).foregroundStyle(palette.mutedInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One source track. Dimmed where it holds nothing and struck through where it is unticked,
    /// which are the two meanings the grid beside it gives the same marks.
    private func trackRow(
        _ row: SourceTrackList.Row, ticked: Bool,
        destination: SourceTrackSelection.Destination, placement: String?
    ) -> some View {
        HStack(spacing: AppLayout.trackColumnGap) {
            Toggle(
                "Import",
                isOn: Binding(
                    get: { ticked }, set: { _ in model.toggle(sourceTrack: row.number) })
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: AppLayout.trackTickWidth, alignment: .leading)
            // The row's label says every one of these, which would otherwise be a stop each.
            Group {
                numberChip(row.number, destination: destination)
                Text(row.name)
                    .font(.caption).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(row.isEmpty ? HierarchicalShapeStyle.secondary : .primary)
                    .strikethrough(!ticked)
                    .frame(
                        minWidth: AppLayout.trackNameMinWidth, maxWidth: .infinity,
                        alignment: .leading)
                badge(row.badge)
                    .frame(width: AppLayout.trackBadgeWidth, alignment: .leading)
                // Kept where counts drops it: a track can carry all sixteen channels, and no fixed
                // width holds that. The whole list is in the row's help.
                Text(row.channels)
                    .font(TypeScale.value).lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(.secondary)
                    .frame(width: AppLayout.trackChannelsWidth, alignment: .leading)
                Text(row.counts)
                    .font(TypeScale.value).lineLimit(1)
                    .foregroundStyle(row.isEmpty ? HierarchicalShapeStyle.tertiary : .secondary)
                    .frame(width: AppLayout.trackCountsWidth, alignment: .leading)
            }
            .accessibilityHidden(true)
            destinationPicker(row, destination: destination, placement: placement)
                .frame(width: AppLayout.trackDestinationWidth, alignment: .leading)
        }
        .opacity(row.isEmpty ? 0.6 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.spoken + (ticked ? "" : ", not imported"))
        .help(row.detail + (ticked ? "" : " · unticked, so it will not be imported"))
    }

    /// Routing made visible at no added row width: the source row takes the colour of the device
    /// row it lands in, and stays inert while it lands nowhere in particular.
    private func numberChip(_ number: Int, destination: SourceTrackSelection.Destination)
        -> some View
    {
        let fill = destination.device.map { DeviceColor.track($0) } ?? palette.inert
        return Text("\(number)")
            .font(TypeScale.smallValue)
            .foregroundStyle(DeviceColor.ink(on: fill))
            .frame(width: AppLayout.trackNumberWidth, height: AppLayout.cellHeight)
            .background(RoundedRectangle(cornerRadius: AppLayout.cellRadius).fill(fill))
    }

    /// A track holding nothing gets no picker: a route naming one is refused, and there is nothing
    /// of it to send anywhere.
    @ViewBuilder
    private func destinationPicker(
        _ row: SourceTrackList.Row, destination: SourceTrackSelection.Destination,
        placement: String?
    ) -> some View {
        if row.isEmpty {
            Color.clear.frame(height: 1)
        } else {
            Picker(
                "Send to",
                selection: Binding(
                    get: { destination },
                    set: { model.send(sourceTrack: row.number, to: $0) })
            ) {
                ForEach(SourceTrackSelection.destinations) {
                    Text(destinationLabel($0, placement: placement)).tag($0)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
    }

    /// The automatic choice reads as where the planner actually put the track, so the default is
    /// the assignment rather than a promise about it.
    private func destinationLabel(
        _ destination: SourceTrackSelection.Destination, placement: String?
    ) -> String {
        guard destination == .automatic, let placement else { return destination.label }
        return "\(destination.label) — \(placement)"
    }

    @ViewBuilder
    func badge(_ badge: SourceTrackList.Badge?) -> some View {
        if let badge {
            // One neutral capsule for all three: the word says which, so no hue has to.
            Text(badge.text)
                .font(.caption2).lineLimit(1)
                .foregroundStyle(palette.mutedInk)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(palette.inert))
        } else {
            Color.clear.frame(height: 1)
        }
    }
}
