import SwiftUI

/// Everything the app remembers that no single conversion decides: which unit it dresses as, where
/// each kind of file lands by default, and how much of a finding list it draws. Appearance is an
/// OS-level affordance and belongs where a Mac user already looks for one (⌘,), not beside the
/// controls that change the file being written.
struct SettingsWindow: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Unit", selection: $model.appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            }

            Section("Destinations") {
                folderRow(.project)
                folderRow(.midi)
            }

            Section("Findings") {
                Toggle("Show every finding", isOn: $model.verbose)
                    .help("List each finding instead of one line per kind.")
            }
        }
        .formStyle(.grouped)
        .frame(width: AppLayout.settingsWidth)
    }

    private var palette: Palette {
        Palette.resolved(for: model.appearance.colorScheme ?? systemScheme)
    }

    @ViewBuilder
    private func folderRow(_ kind: FolderKind) -> some View {
        LabeledContent(kind.title) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.folders.description(of: kind))
                    .font(TypeScale.label).foregroundStyle(palette.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                    // `description(of:)` tildes the path, so the full one has to be reachable.
                    .help(model.folders[kind]?.path ?? kind.defaultDescription)

                HStack(spacing: 8) {
                    Button("Choose…") { model.choose(kind) }
                    if model.folders[kind] != nil {
                        Button("Use default") { model.useDefault(for: kind) }
                            .buttonStyle(.link)
                    }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if kind == .project, let warning = model.mccWarning {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(TypeScale.label).foregroundStyle(palette.warning)
        }
    }
}
