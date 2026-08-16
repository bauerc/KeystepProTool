import AppKit
import SwiftUI

struct DropView: View {
    @Bindable var model: AppModel
    @State private var targeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 16) {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)

            Divider()
            options
        }
        .frame(width: 620, height: 380)
        .dropDestination(for: URL.self) { urls, _ in
            // One file at a time in v1: a second would need its own name field and its own result.
            guard let first = urls.first else { return false }
            model.accept(first)
            return true
        } isTargeted: {
            targeted = $0
        }
        .background(targeted ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    /// The sidebar is on screen in every phase, including idle, so an option can be set before
    /// anything is dropped. Later options land here beside these two.
    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Options").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Dry run", isOn: $model.settings.dryRun)
                Text("Report what would be written, and write nothing.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show every finding", isOn: $model.settings.verbose)
                Text("List each finding instead of one line per kind.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()
        }
        .toggleStyle(.checkbox)
        .frame(width: 180, alignment: .leading)
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            idle
        case .staged(let staged):
            self.staged(staged)
        case .working(let filename):
            ProgressView("Converting \(filename)…")
        case .done(let outcome):
            done(outcome)
        }
    }

    private var idle: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Drop a MIDI file here").font(.title3)
            Text(
                "A KeyStep Pro project lands in MIDI Control Center's Templates folder. "
                    + "Drop a .KeyStepPro instead to get a MIDI file beside it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
    }

    /// What was dropped, which way it goes and where it would land -- shown before anything is
    /// written, which is the whole point of the phase.
    @ViewBuilder
    private func staged(_ staged: AppModel.Staged) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(staged.plan.source.lastPathComponent, systemImage: "doc")
                .font(.headline)
            Text(staged.plan.job.direction).font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Will be written to").font(.caption).foregroundStyle(.secondary)
                Text(staged.plan.target.path).font(.callout).textSelection(.enabled)
            }

            if let note = staged.plan.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }

            if let preview = staged.preview {
                Divider()
                dryRunPreview(preview)
            }

            Spacer()
            HStack {
                Button("Cancel") { model.cancel() }
                Spacer()
                Button(model.settings.dryRun ? "Dry run" : "Convert") {
                    Task { await model.convert() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func dryRunPreview(_ preview: Outcome) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                preview.failed
                    ? "Nothing would be written"
                    : "Would write \(preview.written?.lastPathComponent ?? "")",
                systemImage: preview.failed ? "exclamationmark.triangle" : "eye"
            )
            .font(.subheadline)
            .foregroundStyle(preview.failed ? Color.orange : Color.secondary)

            Text(preview.headline).font(.caption).textSelection(.enabled)
            findings(preview)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func done(_ outcome: Outcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                outcome.failed ? "Nothing was written" : outcome.written?.lastPathComponent ?? "",
                systemImage: outcome.failed ? "exclamationmark.triangle" : "checkmark.circle"
            )
            .font(.headline)
            .foregroundStyle(outcome.failed ? Color.orange : Color.green)

            Text(outcome.headline).font(.callout).textSelection(.enabled)

            if outcome.wroteFile {
                HStack {
                    TextField("Name", text: $model.name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.renameResult() }
                    Button("Rename") { model.renameResult() }
                }
                Text("This is the name MIDI Control Center's Project Browser will show.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let note = outcome.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }

            findings(outcome)

            Spacer()
            Button("Convert another") { model.reset() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Collapsed behind a disclosure either way; the sidebar's toggle is what decides whether the
    /// list inside is one line per kind or one per occurrence.
    @ViewBuilder
    private func findings(_ outcome: Outcome) -> some View {
        if !outcome.all.isEmpty {
            DisclosureGroup("\(outcome.all.count) note(s)") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(outcome.findings(verbose: model.settings.verbose), id: \.self) {
                        finding in
                        Text(finding).font(.caption).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
