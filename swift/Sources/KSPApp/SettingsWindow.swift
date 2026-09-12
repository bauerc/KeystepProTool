import SwiftUI

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
