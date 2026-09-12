import AppKit
import KSPKit
import KSPMIDI
import KSPRun
import SwiftUI

/// The window's furniture: the title, the action bar, and the card and
/// section shells every pane is laid out in.
extension DropView {
    /// Where the result lands and the button that writes it, across the foot of the window: a
    /// commit action belongs beside what it acts on, which is not a pane's height above it.
    var actionBar: some View {
        HStack(spacing: 10) {
            landing
            Spacer(minLength: 12)
            dryRunToggle
            action
        }
        .padding(.horizontal, AppLayout.mainPadding)
        .frame(height: AppLayout.actionBarHeight)
        .frame(maxWidth: .infinity)
        .background(palette.surface)
    }

    /// Beside Convert, which reads "Dry run" while it is on: what a run will and will not write is
    /// one decision, so the switch and the button that obeys it are one control group.
    @ViewBuilder
    private var dryRunToggle: some View {
        if case .staged = model.phase {
            Toggle("Dry run", isOn: $model.settings.dryRun)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Report what would be written, and write nothing.")
            Divider().frame(height: AppLayout.footerDividerHeight)
        }
    }

    @ViewBuilder
    private var landing: some View {
        switch model.phase {
        // A refused file has nowhere to land, so the slot says so rather than naming a path
        // the app has already declined to write.
        case .staged(let staged) where staged.isUnreadable:
            Text(Landing.nowhere)
                .font(TypeScale.label).foregroundStyle(palette.mutedInk)
                .lineLimit(1).truncationMode(.tail)
        case .staged(let staged):
            landingRow(Landing(model.plan(for: staged.job)), kind: staged.job.folderKind)
        case .done(let outcome):
            if let landing = Landing(outcome) { landingPath(landing) }
        default:
            EmptyView()
        }
    }

    private func landingRow(_ landing: Landing, kind: FolderKind) -> some View {
        HStack(spacing: 8) {
            landingPath(landing)
            Button("Choose…") { model.choose(kind) }
                .controlSize(.small)
        }
    }

    /// The folder gives way first: the name is what the user typed, and the head of a path is
    /// the part they can spare.
    private func landingPath(_ landing: Landing) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "folder").foregroundStyle(palette.mutedInk)
            Text(landing.folder)
                .foregroundStyle(palette.mutedInk)
                .lineLimit(1).truncationMode(.head)
            Text("/").foregroundStyle(palette.mutedInk)
            Text(landing.name).lineLimit(1).layoutPriority(1)
        }
        .font(TypeScale.label)
        .help(landing.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(landing.spoken)
    }

    /// The action slot, which is never empty while an action can be taken: Convert while a file
    /// is staged, the way back once one is written, and the way in while nothing is.
    @ViewBuilder
    var action: some View {
        switch model.phase {
        case .staged:
            if let reason = model.blockReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(TypeScale.label).foregroundStyle(palette.warning)
                    .lineLimit(1).truncationMode(.tail)
            }
            Button("Cancel") { model.cancel() }
            Button(model.settings.dryRun ? "Dry run" : "Convert") {
                Task { await model.convert() }
            }
            .disabled(model.blockReason != nil)
            .keyboardShortcut(.defaultAction)
        case .done(let outcome):
            if !outcome.failed {
                Button("Reveal in Finder") { model.revealWritten() }
            }
            Button(outcome.againLabel) { model.reset() }
        case .idle:
            // Return belongs to the device card's own button here, so this takes no default
            // action: two of them in one phase is a coin toss over which one Return reaches.
            Button("Open…") { model.open() }
        default:
            EmptyView()
        }
    }

    /// Rank from size and the space above it, not a coloured rail: saturated colour is kept for
    /// what the reader can act on.
    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(TypeScale.header)
    }

    /// The one container: the device panel wears it, and so does each phase of a conversion.
    func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppLayout.cardSpacing) { content() }
            .padding(AppLayout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppLayout.cardRadius).fill(palette.surface))
    }

    func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title)
            card(content)
        }
    }

    /// One row under a rule, in the card of the thing it changes, so the section reads as source
    /// and then what may be done to it rather than as two unrelated blocks.
    func optionBand<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: AppLayout.bandGap) {
            content()
            Spacer(minLength: 0)
        }
        .font(TypeScale.label)
        .controlSize(.small)
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var bandDivider: some View {
        Divider().frame(height: AppLayout.bandDividerHeight)
    }
}
