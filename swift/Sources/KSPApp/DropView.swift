import AppKit
import KSPKit
import KSPRun
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
        // Taller than v1's 380: the staged view now carries a summary above the buttons, and the
        // rest of it must not be squeezed to make room.
        .frame(width: 680, height: 440)
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
    /// anything is dropped. Later options land here beside these. Scrolls because the window is
    /// fixed-size: a control added below must push, not clip.
    private var options: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Destinations").font(.headline)
                folderRow(.project)
                folderRow(.midi)

                Divider()

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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .toggleStyle(.checkbox)
        .frame(width: 220)
    }

    /// One kind of file: where it lands today, the way to change that, and the way back. The two
    /// rows are independent -- a project and a MIDI file need not go to the same place.
    private func folderRow(_ kind: FolderKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.title).font(.subheadline)

            Text(model.folders.description(of: kind))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
                // Abbreviated to fit the sidebar, so the full path has to be reachable somewhere.
                .help(model.folders[kind]?.path ?? kind.defaultDescription)

            HStack(spacing: 8) {
                Button("Choose…") { model.choose(kind) }
                if model.folders[kind] != nil {
                    Button("Use default") { model.useDefault(for: kind) }
                        .buttonStyle(.link)
                }
            }
            .controlSize(.small)

            // What a chosen project folder costs, said where the choice was made.
            if kind == .project, let warning = model.mccWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            // Where each one lands is the sidebar's to state, now that it can be changed there.
            Text(
                "Drop a .KeyStepPro instead to get a MIDI file back. "
                    + "Where each one lands is on the right."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
    }

    /// What was dropped, what it will be called and where it will land -- all before anything is
    /// written, which is the whole point of the phase.
    private func staged(_ staged: AppModel.Staged) -> some View {
        let plan = model.plan(for: staged.job)
        // The window cannot be resized, and a summary, a note and an expanded findings list can
        // together outgrow it. So everything above the buttons scrolls and the buttons stay put --
        // Cancel and Convert must never be the part that goes over the edge.
        return VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label(plan.source.lastPathComponent, systemImage: "doc")
                        .font(.headline)
                    Text(staged.job.direction).font(.callout).foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name", text: $model.name)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: model.name) { model.discardPreview() }
                        Text("This is the name MIDI Control Center's Project Browser will show.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Will be written to").font(.caption).foregroundStyle(.secondary)
                        Text(plan.target.path).font(.callout).textSelection(.enabled)
                    }

                    if let note = plan.note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }

                    if staged.summary != .absent {
                        Divider()
                        summary(staged.summary)
                    }

                    if let preview = staged.preview {
                        Divider()
                        dryRunPreview(preview)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

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
        // Reading a 3.5 MB project is the model's to do off the main actor; this only asks for it.
        // Keyed on the drop rather than its path, so dropping the same file again reads it again.
        .task(id: staged.id) { await model.summarise() }
    }

    /// What was dropped, before anything is converted.
    ///
    /// Nothing is drawn for a MIDI file: there is no project to read. A project that will not read
    /// says so here, which is the alternative to an empty list.
    @ViewBuilder
    private func summary(_ state: SummaryState) -> some View {
        switch state {
        case .absent:
            EmptyView()
        case .loading:
            ProgressView("Reading the project…").controlSize(.small)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        case .ready(let summary):
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "\(Arithmetic.general(summary.tempoBPM)) BPM · swing "
                        + "\(summary.globalSwingPercent)% · scene \(summary.currentScene)"
                )
                .font(.caption).foregroundStyle(.secondary)

                // Not scrolled here: the staged view already scrolls as a whole, and a second
                // scroller inside the first is a trap for a mouse wheel.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(summary.tracks, id: \.number, content: trackRow)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One track: what it is, how much is switched on in it, and all sixteen slots -- shown as two
    /// rows of eight rather than a grid, which is #128's job and not this one's.
    private func trackRow(_ track: TrackSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(track.name).font(.caption).fontWeight(.medium)
                Spacer()
                Text(trackDetail(track)).font(.caption).foregroundStyle(.secondary)
            }

            ForEach(Array(stride(from: 0, to: track.patterns.count, by: 8)), id: \.self) { start in
                HStack(spacing: 6) {
                    ForEach(
                        track.patterns[start..<min(start + 8, track.patterns.count)], id: \.number
                    ) { pattern in
                        slot(pattern, in: track)
                    }
                }
            }
        }
    }

    /// One pattern slot. Dimmed when it holds nothing at all; otherwise its number and how many of
    /// its notes are switched on -- so a pattern whose every step is off reads `3·0`, which a dimmed
    /// cell could not say.
    private func slot(_ pattern: PatternSummary, in track: TrackSummary) -> some View {
        Text(
            pattern.isEmpty ? "\(pattern.number)" : "\(pattern.number)·\(pattern.enabledNoteCount)"
        )
        .font(.caption).monospacedDigit()
        .foregroundStyle(pattern.isEmpty ? Color.secondary : Color.primary)
        .frame(maxWidth: .infinity)
        .help(slotDetail(pattern, in: track))
    }

    /// Held and switched on are counted side by side rather than as a fraction: a pattern can hold
    /// the other set's notes too, and what closed the gap is the diagnostics' to say, not a tooltip's.
    /// Switched on is not audible either -- it is the two switches the device offers, not the six
    /// reasons a note might not sound.
    private func slotDetail(_ pattern: PatternSummary, in track: TrackSummary) -> String {
        guard !pattern.isEmpty else { return "Pattern \(pattern.number) — empty" }
        let noun = track.mode == .drum ? "triggers" : "notes"
        return "Pattern \(pattern.number) — \(pattern.noteCount) \(noun) held, "
            + "\(pattern.enabledNoteCount) switched on, \(pattern.stepCount) steps"
    }

    /// Says "switched on" because that is what the number is -- the same count the slots carry, not
    /// everything the track holds.
    private func trackDetail(_ track: TrackSummary) -> String {
        guard !track.isEmpty else { return "empty" }
        let held = track.patterns.count(where: { !$0.isEmpty })
        let notes = track.patterns.reduce(0) { $0 + $1.enabledNoteCount }
        let noun = track.mode == .drum ? "trigger" : "note"
        return "\(held) pattern\(held == 1 ? "" : "s") · \(notes) "
            + "\(noun)\(notes == 1 ? "" : "s") switched on"
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

            if let note = outcome.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }

            findings(outcome)

            Spacer()
            Button("Convert another") { model.reset() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The sidebar's toggle decides whether the list inside is one line per kind or one per
    /// occurrence. "Finding", not "note": a note is a melodic event (ADR 0001).
    @ViewBuilder
    private func findings(_ outcome: Outcome) -> some View {
        if !outcome.all.isEmpty {
            DisclosureGroup("\(outcome.all.count) finding(s)") {
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
