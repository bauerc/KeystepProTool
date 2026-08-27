import AppKit
import KSPKit
import KSPMIDI
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

    /// Scrolls because the window is fixed-size: a control added below must push, not clip.
    private var options: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Destinations").font(.headline)
                folderRow(.project)
                folderRow(.midi)

                Divider()

                Text("MIDI export").font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $model.settings.splitPerPattern) {
                        Text("One file for everything").tag(false)
                        Text("One file per pattern slot").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .onChange(of: model.settings.splitPerPattern) { model.discardPreview() }
                    Text("Each file holds one pattern slot and starts at its own bar 1.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Step Skip").font(.subheadline)

                    Picker("Step Skip", selection: $model.settings.stepSkip) {
                        ForEach(Settings.StepSkip.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .onChange(of: model.settings.stepSkip) { model.discardPreview() }

                    Text(
                        "Auto expands the device's 16/32/48/64 cycle to four passes when a note "
                            + "skips part of it; 1 flattens the cycle to a single pass that plays "
                            + "every note whatever its mask. This is the device's own cycle, not "
                            + "copies of the export."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Stepper(value: $model.settings.repeatCount, in: Settings.repeatRange) {
                        Text("Repeat ×\(model.settings.repeatCount)").font(.subheadline)
                    }
                    .controlSize(.small)
                    .onChange(of: model.settings.repeatCount) { model.discardPreview() }

                    Text(
                        "Lay the whole export down this many times end to end. This one is not the "
                            + "cycle above: it exists only in the .mid, and the device stores no "
                            + "such count, so no repeat of it can be written back to a project."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }

                replacements

                Divider()

                Text("MIDI import").font(.headline)

                ignores

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

    /// Swing here is the export's sense: flattening the grid, not declining to fit one to a source.
    private var replacements: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Replace with defaults").font(.subheadline)

            substitution(
                "Velocity", isOn: $model.settings.replaceVelocity,
                note: "Every note and trigger at the fresh-note velocity, "
                    + "\(MIDIExport.defaultFlatVelocity), not the one it stores.")
            substitution(
                "Swing", isOn: $model.settings.replaceSwing,
                note: "Every step on a flat grid, not the delay the pattern's swing applies.")
            substitution(
                "Time Shift", isOn: $model.settings.replaceTimeShift,
                note: "Every step on the grid, not the offset the note stores.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Swing here is the import's sense: declining to fit one to the source, not flattening a grid
    /// the project already stores.
    private var ignores: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ignore in the source").font(.subheadline)

            substitution(
                "Velocity", isOn: $model.settings.ignoreVelocity,
                note: "Every note and trigger written at the fresh-note velocity, "
                    + "\(MIDIExport.defaultFlatVelocity), not the source's own.")
            substitution(
                "Swing Fitting", isOn: $model.settings.ignoreSwing,
                note: "Every pattern left straight at \(Constants.swingRangePercent.min)%, "
                    + "not fitted to the source's groove.")
            substitution(
                "Time Shift", isOn: $model.settings.ignoreTimeShift,
                note: "Every note quantised hard to its step at a time shift of 0, not given "
                    + "the leftover it would otherwise keep.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func substitution(_ title: String, isOn: Binding<Bool>, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
                .onChange(of: isOn.wrappedValue) { model.discardPreview() }
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

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
            Text(
                "Drop a .KeyStepPro instead to get a MIDI file back. "
                    + "Where each one lands is on the right."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
    }

    private func staged(_ staged: AppModel.Staged) -> some View {
        let plan = model.plan(for: staged.job)
        // The window cannot be resized, so everything above the buttons scrolls and they stay put.
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
                        Text(nameNote(plan))
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.intoFolder ? "Will be written into" : "Will be written to")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(plan.target.path).font(.callout).textSelection(.enabled)
                    }

                    if let note = plan.note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }

                    Divider()
                    summary(staged)

                    if let excluded = [
                        staged.selection.exclusionNote, staged.sourceSelection.exclusionNote,
                    ].compactMap({ $0 }).first {
                        Text(excluded).font(.caption).foregroundStyle(.secondary)
                    }

                    // Only on the way out: these three mean something else on an import.
                    if staged.job.writesMIDI, let replaced = model.settings.replacementNote {
                        Text(replaced).font(.caption).foregroundStyle(.secondary)
                    }

                    if !staged.job.writesMIDI, let ignored = model.settings.ignoredNote {
                        Text(ignored).font(.caption).foregroundStyle(.secondary)
                    }

                    if let preview = staged.preview {
                        Divider()
                        dryRunPreview(preview)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .firstTextBaseline) {
                Button("Cancel") { model.cancel() }
                Spacer()
                if let reason = model.blockReason {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(model.settings.dryRun ? "Dry run" : "Convert") {
                    Task { await model.convert() }
                }
                .disabled(model.blockReason != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: staged.id) { await model.summarise() }
    }

    @ViewBuilder
    private func summary(_ staged: AppModel.Staged) -> some View {
        switch staged.summary {
        case .loading:
            ProgressView(staged.job.isProject ? "Reading the project…" : "Reading the MIDI file…")
                .controlSize(.small)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        case .project(let summary):
            grid(
                PatternGrid(summary), selection: staged.selection,
                length: ExportLength(
                    summary, selection: staged.selection,
                    repeatCount: model.settings.repeatCount,
                    isSplit: model.settings.splitPerPattern))
        case .song(let summary):
            trackList(SourceTrackList(summary), selection: staged.sourceSelection)
        }
    }

    /// Unscrolled, like ``grid(_:selection:length:)``: the staged view already scrolls.
    private func trackList(_ list: SourceTrackList, selection: SourceTrackSelection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(list.header).font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(list.rows, id: \.number) {
                    trackRow($0, ticked: selection.isTicked($0.number))
                }
            }

            if let count = selection.countLine {
                Text(count).font(.caption).foregroundStyle(.secondary)
            }

            // Ticking past the device's four is flagged, not refused, so Convert stays enabled.
            if let overflow = selection.overflowNote {
                Label(overflow, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = list.note(verbose: model.settings.verbose) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }

            Text(SourceTrackList.legend).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One source track. Dimmed where it holds nothing and struck through where it is unticked,
    /// which are the two meanings the grid beside it gives the same marks.
    private func trackRow(_ row: SourceTrackList.Row, ticked: Bool) -> some View {
        HStack(spacing: AppLayout.trackColumnGap) {
            Toggle(
                "",
                isOn: Binding(
                    get: { ticked }, set: { _ in model.toggle(sourceTrack: row.number) })
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: AppLayout.trackTickWidth, alignment: .leading)
            Text("\(row.number)")
                .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                .frame(width: AppLayout.trackNumberWidth, alignment: .trailing)
            Text(row.name)
                .font(.caption).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(row.isEmpty ? HierarchicalShapeStyle.secondary : .primary)
                .strikethrough(!ticked)
                .frame(width: AppLayout.trackNameWidth, alignment: .leading)
            badge(row.badge)
                .frame(width: AppLayout.trackBadgeWidth, alignment: .leading)
            Text(row.channels)
                .font(.caption).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(.secondary)
                .frame(width: AppLayout.trackChannelsWidth, alignment: .leading)
            Text(row.counts)
                .font(.caption).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(row.isEmpty ? HierarchicalShapeStyle.tertiary : .secondary)
                .frame(width: AppLayout.trackCountsWidth, alignment: .leading)
        }
        .opacity(row.isEmpty ? 0.6 : 1)
        .contentShape(Rectangle())
        .help(row.detail + (ticked ? "" : " · unticked, so it will not be imported"))
    }

    @ViewBuilder
    private func badge(_ badge: SourceTrackList.Badge?) -> some View {
        if let badge {
            Text(badge.text)
                .font(.caption2).lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(
                    Capsule().fill(
                        badge == .drums
                            ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12))
                )
        } else {
            Color.clear.frame(height: 1)
        }
    }

    /// Not scrolled: the staged view already scrolls, and a scroller inside one traps the wheel.
    private func grid(_ grid: PatternGrid, selection: GridSelection, length: ExportLength)
        -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            Text(grid.header).font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: AppLayout.gridOrigin, height: 1)
                    HStack(spacing: AppLayout.cellSpacing) {
                        ForEach(grid.columns, id: \.self) { column in
                            columnHeader(column, state: selection.state(ofPattern: column))
                        }
                    }
                }
                ForEach(grid.rows, id: \.track) { trackRow($0, selection: selection) }
            }

            if let line = length.line {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }

            Text(PatternGrid.legend).font(.caption2).foregroundStyle(.secondary)
            Text(GridSelection.legend).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func columnHeader(_ column: Int, state: GridSelection.Tick) -> some View {
        Button {
            model.toggle(pattern: column)
        } label: {
            Text("\(column)")
                .font(.caption2).monospacedDigit()
                .foregroundStyle(state == .on ? HierarchicalShapeStyle.secondary : .tertiary)
                .strikethrough(state == .off)
                .frame(width: AppLayout.cellWidth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            state == .on
                ? "Pattern slot \(column) — click to untick it on every track."
                : "Pattern slot \(column) — click to tick it on every track.")
    }

    /// One track: its name, its cells, the rails joining whatever it chains, and the chain beneath.
    private func trackRow(_ row: PatternGrid.Row, selection: GridSelection) -> some View {
        let state = selection.state(ofTrack: row.track)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                Button {
                    model.toggle(track: row.track)
                } label: {
                    Text(row.name)
                        .font(.caption).fontWeight(.medium).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(state == .on ? HierarchicalShapeStyle.primary : .secondary)
                        .strikethrough(state == .off)
                        .frame(width: AppLayout.labelWidth, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(
                    row.detail
                        + (state == .on
                            ? " · Click to untick this whole track."
                            : " · Click to tick this whole track."))
                Color.clear.frame(width: AppLayout.labelGap, height: 1)
                HStack(spacing: AppLayout.cellSpacing) {
                    ForEach(row.cells, id: \.pattern) {
                        slot($0, track: row.track, selection: selection)
                    }
                }
            }
            .padding(.bottom, 4)
            // Under the cells, not behind them: a rail and a cell's tint would otherwise band.
            .overlay(alignment: .bottomLeading) { rails(row.runs) }

            if let chain = row.chainDetail {
                Text(chain)
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.leading, AppLayout.gridOrigin)
            }
        }
    }

    /// A chain that jumps gets no bar; its cells are still tinted, and the caption says the order.
    private func rails(_ runs: [PatternGrid.ChainRun]) -> some View {
        ForEach(runs.indices, id: \.self) { index in
            Capsule()
                .fill(Color.accentColor)
                .frame(width: runs[index].width, height: 2)
                .offset(x: runs[index].x)
        }
    }

    /// An em dash means the slot holds nothing; `0` means it holds notes with every step off.
    private func slot(_ cell: PatternGrid.Cell, track: Int, selection: GridSelection) -> some View {
        let ticked = selection.isTicked(track: track, pattern: cell.pattern)
        return Button {
            model.toggle(track: track, pattern: cell.pattern)
        } label: {
            Text(cell.label)
                .font(.caption).monospacedDigit()
                // Shrunk rather than truncated: a count reading "1…" would be worse than small.
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(cell.isEmpty || !ticked ? Color.secondary : Color.primary)
                .opacity(ticked ? 1 : 0.5)
                .frame(width: AppLayout.cellWidth, height: AppLayout.cellHeight)
                .background(
                    RoundedRectangle(cornerRadius: 3).fill(ticked ? fill(cell) : .clear)
                )
                // Dashed, not merely dimmer: an empty cell is already faint.
                .overlay {
                    if !ticked {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(
                                Color.secondary.opacity(0.7),
                                style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(cell.detail + (ticked ? "" : " · unticked, so it will not be exported"))
    }

    /// Chained first: a Chain can name a slot that holds nothing and the device still plays it.
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

            if let folder = preview.folder { landedIn(folder) }
            if preview.written.count > 1 || preview.folder != nil {
                writtenFiles(preview.written)
            }

            Text(preview.headline).font(.caption).textSelection(.enabled)
            findings(preview)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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

                    if let folder = outcome.folder { landedIn(folder) }
                    if outcome.written.count > 1 || outcome.folder != nil {
                        writtenFiles(outcome.written)
                    }

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

    /// A split run names its own files, so the name reaches the folder they land in instead.
    private func nameNote(_ plan: Conversion.Plan) -> String {
        plan.intoFolder
            ? "This names the folder the files land in. Each file is named after the project and "
                + "the slot it holds."
            : "This is the name MIDI Control Center's Project Browser will show."
    }

    private func landedIn(_ folder: URL) -> some View {
        Text(folder.path).font(.callout).textSelection(.enabled)
    }

    private func writtenFiles(_ written: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(written, id: \.self) { url in
                Text(url.lastPathComponent).font(.caption).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Finding", not "note": a note is a melodic event (ADR 0001).
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
