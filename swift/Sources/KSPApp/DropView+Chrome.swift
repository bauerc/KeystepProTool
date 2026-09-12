import AppKit
import KSPKit
import KSPMIDI
import KSPRun
import SwiftUI

extension DropView {
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
            Button("Open…") { model.open() }
        default:
            EmptyView()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(TypeScale.header)
    }

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
