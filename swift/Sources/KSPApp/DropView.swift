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
            .padding(AppLayout.mainPadding)

            Divider()
            options
        }
        // Taller than v1's 380, and wider than its 680: the staged view now carries a sixteen-slot
        // grid above the buttons, and the pattern axis must not be squeezed to make room. Every
        // dimension comes from ``AppLayout``, which is where the fit is worked out and tested.
        .frame(width: AppLayout.windowWidth, height: AppLayout.windowHeight)
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
        .frame(width: AppLayout.sidebarWidth)
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

                    // A name renames one file. A run writing several has no one file to apply it
                    // to, so the field is not offered at all.
                    if plan.writesOneFile {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Name", text: $model.name)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: model.name) { model.discardPreview() }
                            Text(
                                "This is the name MIDI Control Center's Project Browser will show."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Will be written to").font(.caption).foregroundStyle(.secondary)
                        ForEach(plan.targets, id: \.self) { target in
                            Text(target.path).font(.callout).textSelection(.enabled)
                        }
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
            grid(PatternGrid(summary))
        }
    }

    /// The project as a grid: four tracks down, sixteen pattern slots across, so how the tracks line
    /// up against each other can be seen rather than counted.
    ///
    /// Every decision here was taken in ``PatternGrid`` -- what a cell says, which cells are joined,
    /// how wide the whole thing comes out. This only draws it.
    ///
    /// Not scrolled: the staged view already scrolls as a whole, and a second scroller inside the
    /// first is a trap for a mouse wheel.
    private func grid(_ grid: PatternGrid) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(grid.header).font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: AppLayout.gridOrigin, height: 1)
                    HStack(spacing: AppLayout.cellSpacing) {
                        ForEach(grid.columns, id: \.self) { column in
                            Text("\(column)")
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: AppLayout.cellWidth)
                        }
                    }
                }
                ForEach(grid.rows, id: \.track, content: trackRow)
            }

            Text(PatternGrid.legend).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One track: its name, its sixteen cells, the rails joining whatever it chains, and the chain
    /// spelled out underneath. The per-track counts are the label's tooltip -- sixteen columns leave
    /// no room to show them outright.
    private func trackRow(_ row: PatternGrid.Row) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                Text(row.name)
                    .font(.caption).fontWeight(.medium).lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: AppLayout.labelWidth, alignment: .leading)
                    .help(row.detail)
                Color.clear.frame(width: AppLayout.labelGap, height: 1)
                HStack(spacing: AppLayout.cellSpacing) {
                    ForEach(row.cells, id: \.pattern, content: slot)
                }
            }
            .padding(.bottom, 4)
            // Drawn under the cells rather than behind them, so a rail and a chained cell's own
            // tint cannot double up into banding across the gaps they are meant to close.
            .overlay(alignment: .bottomLeading) { rails(row.runs) }

            if let chain = row.chainDetail {
                Text(chain)
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.leading, AppLayout.gridOrigin)
            }
        }
    }

    /// One continuous bar per run of chained slots that are neighbours in both play order and grid
    /// order. A chain that jumps gets no bar -- its cells are still tinted, and the caption under
    /// the row says the order.
    private func rails(_ runs: [PatternGrid.ChainRun]) -> some View {
        ForEach(runs.indices, id: \.self) { index in
            Capsule()
                .fill(Color.accentColor)
                .frame(width: runs[index].width, height: 2)
                .offset(x: runs[index].x)
        }
    }

    /// One pattern slot. The column header carries its number now, so the cell is free to print the
    /// count: an em dash when it holds nothing at all, and otherwise how many of its events are
    /// switched on -- so a Pattern whose every step is off reads `0` on a filled cell rather than
    /// passing as empty.
    private func slot(_ cell: PatternGrid.Cell) -> some View {
        Text(cell.label)
            .font(.caption).monospacedDigit()
            // Shrunk rather than truncated: a count reading "1…" would be the one thing a cell is
            // for. Three digits fit outright; the scale factor is what a fourth would use.
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(cell.isEmpty ? Color.secondary : Color.primary)
            .frame(width: AppLayout.cellWidth, height: AppLayout.cellHeight)
            .background(
                RoundedRectangle(cornerRadius: 3).fill(fill(cell))
            )
            .help(cell.detail)
    }

    /// Chained first, because a Chain can name a slot that holds nothing and the device still plays
    /// it -- so that slot has to read as part of the run rather than as absent.
    private func fill(_ cell: PatternGrid.Cell) -> Color {
        if !cell.positions.isEmpty { return Color.accentColor.opacity(0.22) }
        if cell.isEmpty { return .clear }
        return Color.secondary.opacity(0.12)
    }

    @ViewBuilder
    private func dryRunPreview(_ preview: Outcome) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                preview.previewLine,
                systemImage: preview.failed ? "exclamationmark.triangle" : "eye"
            )
            .font(.subheadline)
            .foregroundStyle(preview.failed ? Color.orange : Color.secondary)

            if preview.written.count > 1 { writtenFiles(preview.written) }

            Text(preview.headline).font(.caption).textSelection(.enabled)
            findings(preview)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What was written, all of it. Shaped like ``staged(_:)`` and for the same reason: the window
    /// is fixed-size, so a list of files scrolls and "Convert another" stays put.
    @ViewBuilder
    private func done(_ outcome: Outcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label(
                        outcome.resultLine,
                        systemImage: outcome.failed
                            ? "exclamationmark.triangle" : "checkmark.circle"
                    )
                    .font(.headline)
                    .foregroundStyle(outcome.failed ? Color.orange : Color.green)

                    if outcome.written.count > 1 { writtenFiles(outcome.written) }

                    Text(outcome.headline).font(.callout).textSelection(.enabled)

                    if let note = outcome.note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }

                    findings(outcome)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Convert another") { model.reset() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The files by name, under a headline that could only give their count.
    private func writtenFiles(_ written: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(written, id: \.self) { url in
                Text(url.lastPathComponent).font(.caption).textSelection(.enabled)
            }
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
