import AppKit
import KSPKit
import KSPMIDI
import KSPRun
import SwiftUI

struct DropView: View {
    @Bindable var model: AppModel
    @State private var targeted = false
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        VStack(spacing: 0) {
            band

            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 12) {
                    content
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(AppLayout.mainPadding)

                Divider()
                options
            }
        }
        .frame(
            minWidth: AppLayout.minimumWindowWidth, maxWidth: .infinity,
            minHeight: AppLayout.minimumWindowHeight, maxHeight: .infinity
        )
        .background(palette.ground)
        .foregroundStyle(palette.ink)
        .toolbar { ToolbarItem(placement: .principal) { modeSwitch } }
        .dropDestination(for: URL.self) { urls, _ in
            // One file at a time in v1: a second would need its own name field and its own result.
            guard let first = urls.first else { return false }
            model.accept(first)
            return true
        } isTargeted: {
            targeted = $0
        }
        .overlay {
            if targeted {
                Rectangle()
                    .strokeBorder(DeviceColor.track(1), lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(model.appearance.colorScheme)
    }

    /// The window follows the system unless the user has named a unit, and the palette follows the
    /// window: the two faces are the standard unit and the Chroma, not light and dark.
    private var scheme: ColorScheme { model.appearance.colorScheme ?? systemScheme }
    private var palette: Palette { Palette.resolved(for: scheme) }

    /// After the panel's matte black band, which carries the display and the four track readouts
    /// above the coloured track zones. It is what keeps the standard unit's face from being a
    /// white void with four coloured rows floating in it.
    private var band: some View {
        HStack(spacing: 10) {
            bandTitle
            Spacer(minLength: 12)
            bandAction
        }
        .padding(.horizontal, AppLayout.mainPadding)
        .frame(height: AppLayout.bandHeight)
        .frame(maxWidth: .infinity)
        .background(palette.band)
        .foregroundStyle(palette.bandInk)
    }

    @ViewBuilder
    private var bandTitle: some View {
        switch model.phase {
        case .idle:
            Text("Key Step Pro Plus").font(TypeScale.bandTitle)
        case .staged(let staged):
            Text(model.plan(for: staged.job).source.lastPathComponent)
                .font(TypeScale.bandTitle).lineLimit(1).truncationMode(.middle)
            Text(staged.job.direction)
                .font(TypeScale.label).foregroundStyle(palette.bandInk.opacity(0.65))
        case .working(let filename):
            Text(filename).font(TypeScale.bandTitle).lineLimit(1).truncationMode(.middle)
        case .done(let outcome):
            // The glyph carries the outcome; the colour only agrees with it. Track 2 is orange and
            // Track 4 is red, so a status hue is never enough on its own.
            Image(systemName: outcome.failed ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(outcome.failed ? palette.warning : palette.success)
            Text(outcome.resultLine).font(TypeScale.bandTitle).lineLimit(1)
        }
    }

    /// Convert lives in the band once the pane below it stops being the only place to put it.
    @ViewBuilder
    private var bandAction: some View {
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
        case .done:
            Button("Convert another") { model.reset() }
        default:
            EmptyView()
        }
    }

    /// In the titlebar, where a view switch belongs and where nothing the pane does can move it.
    private var modeSwitch: some View {
        Picker("", selection: $model.mode) {
            ForEach(Mode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// A fixed-width column, so a control added below must push, not widen or clip. Simple keeps
    /// the destinations, the appearance and the dry run, and drops the groups that reshape a
    /// conversion: what those do is the part worth choosing a face for.
    private var options: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("Destinations")
                folderRow(.project)
                folderRow(.midi)

                Divider()

                // Shown under Simple too, unlike every other control here: it says which unit the
                // app dresses as, not what a conversion does, so Simple's "defaults only" rule
                // does not reach it.
                sectionHeader("Appearance")
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $model.appearance) {
                        ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text("Standard is the white unit, Chroma the dark one.")
                        .font(TypeScale.label).foregroundStyle(palette.mutedInk)
                }

                if model.mode == .advanced {
                    Divider()

                    // One group, never both: the panel writes to the slot ``kind`` names, so a
                    // control from the other direction would take an edit that slot never reads.
                    if model.kind == .toMIDI { exportGroup } else { importGroup }
                }

                Divider()

                sectionHeader("Options")

                // Shown under Simple too: writing nothing is not an advanced thing to ask for, and
                // Convert reads "Dry run" while it is on, so it cannot be left set unnoticed.
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Dry run", isOn: $model.settings.dryRun)
                    Text("Report what would be written, and write nothing.")
                        .font(TypeScale.label).foregroundStyle(palette.mutedInk)
                }

                if model.mode == .advanced {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Show every finding", isOn: $model.settings.verbose)
                        Text("List each finding instead of one line per kind.")
                            .font(TypeScale.label).foregroundStyle(palette.mutedInk)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .toggleStyle(.checkbox)
        .frame(width: AppLayout.sidebarWidth)
    }

    /// Blue rules a secondary section, after the panel's 63 SHIFT functions in blue silkscreen. It
    /// marks rather than letters: at #16B4E9 the hue cannot carry text on the standard unit's
    /// ground, and no hue in this app is allowed to.
    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(DeviceColor.secondary)
                .frame(width: 3, height: 13)
            Text(title).font(TypeScale.bandTitle)
        }
    }

    @ViewBuilder
    private var exportGroup: some View {
        sectionHeader("MIDI export")

        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: $model.settings.splitPerPattern) {
                Text("One file for everything").tag(false)
                Text("One file per pattern slot").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onChange(of: model.settings.splitPerPattern) { model.discardPreview() }
            Text("Each file holds one pattern slot and starts at its own bar 1.")
                .font(TypeScale.label).foregroundStyle(palette.mutedInk)
        }

        VStack(alignment: .leading, spacing: 4) {
            Text("Step Skip").font(TypeScale.sectionTitle)

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
            .font(TypeScale.label).foregroundStyle(palette.mutedInk)
        }

        VStack(alignment: .leading, spacing: 4) {
            Stepper(value: $model.settings.repeatCount, in: Settings.repeatRange) {
                Text("Repeat ×\(model.settings.repeatCount)").font(TypeScale.sectionTitle)
            }
            .controlSize(.small)
            .onChange(of: model.settings.repeatCount) { model.discardPreview() }

            Text(
                "Lay the whole export down this many times end to end. This one is not the "
                    + "cycle above: it exists only in the .mid, and the device stores no "
                    + "such count, so no repeat of it can be written back to a project."
            )
            .font(TypeScale.label).foregroundStyle(palette.mutedInk)
        }

        replacements
    }

    @ViewBuilder
    private var importGroup: some View {
        sectionHeader("MIDI import")

        ignores
    }

    /// Swing here is the export's sense: flattening the grid, not declining to fit one to a source.
    private var replacements: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Replace with defaults").font(TypeScale.sectionTitle)

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
            Text("Ignore in the source").font(TypeScale.sectionTitle)

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
            Text(note).font(TypeScale.label).foregroundStyle(palette.mutedInk)
        }
    }

    private func folderRow(_ kind: FolderKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.title).font(TypeScale.sectionTitle)

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

            if kind == .project, let warning = model.mccWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(TypeScale.label).foregroundStyle(palette.warning)
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
                .foregroundStyle(palette.mutedInk)
            Text("Drop a MIDI file here").font(.title3)
            Text(
                "Drop a .KeyStepPro instead to get a MIDI file back. "
                    + "Where each one lands is on the right."
            )
            .font(TypeScale.label)
            .foregroundStyle(palette.mutedInk)
            .multilineTextAlignment(.center)
        }
    }

    private func staged(_ staged: AppModel.Staged) -> some View {
        let plan = model.plan(for: staged.job)
        // Cancel and Convert sit outside the scroll view, so they stay reachable at any height.
        return VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name", text: $model.name)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: model.name) { model.discardPreview() }
                        Text(nameNote(plan))
                            .font(TypeScale.label).foregroundStyle(palette.mutedInk)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.intoFolder ? "Will be written into" : "Will be written to")
                            .font(TypeScale.label).foregroundStyle(palette.mutedInk)
                        Text(plan.target.path).font(.callout).textSelection(.enabled)
                    }

                    if let note = plan.note {
                        Text(note).font(TypeScale.label).foregroundStyle(palette.mutedInk)
                    }

                    Divider()
                    summary(staged)

                    if let excluded = model.exclusionNote {
                        Text(excluded).font(TypeScale.label).foregroundStyle(palette.mutedInk)
                    }

                    // Only on the way out: these three mean something else on an import. Both notes
                    // are nil on the defaults, so Simple drops them without a face of its own.
                    if staged.job.writesMIDI, let replaced = model.settings.replacementNote {
                        Text(replaced).font(TypeScale.label).foregroundStyle(palette.mutedInk)
                    }

                    if !staged.job.writesMIDI, let ignored = model.settings.ignoredNote {
                        Text(ignored).font(TypeScale.label).foregroundStyle(palette.mutedInk)
                    }

                    if let preview = staged.preview {
                        Divider()
                        dryRunPreview(preview)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: staged.id) { await model.summarise() }
        .task(id: model.segmentationKey) { await model.segment() }
    }

    @ViewBuilder
    private func summary(_ staged: AppModel.Staged) -> some View {
        switch staged.summary {
        case .loading:
            ProgressView(staged.job.isProject ? "Reading the project…" : "Reading the MIDI file…")
                .controlSize(.small)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(TypeScale.label).foregroundStyle(palette.warning).textSelection(.enabled)
        case .project(let summary):
            grid(
                PatternGrid(summary), selection: staged.selection,
                length: ExportLength(
                    summary, selection: staged.selection,
                    repeatCount: model.settings.repeatCount,
                    isSplit: model.settings.splitPerPattern))
        case .song(let summary):
            VStack(alignment: .leading, spacing: 12) {
                trackList(
                    SourceTrackList(summary), selection: staged.sourceSelection,
                    placements: placements(staged.segmentation))
                Divider()
                segmentation(staged.segmentation)
            }
        }
    }

    /// Read-only, and redrawn whenever the ticks or a setting move it: what the planner says the
    /// import would lay down, rather than what the file holds.
    @ViewBuilder
    private func segmentation(_ state: SegmentationState) -> some View {
        switch state {
        case .loading:
            ProgressView("Planning the import…").controlSize(.small)
        case .failed(let message):
            // Not drawn as an exceeded limit: an unreadable file and a single-target import fail
            // the same way, and only the planner's own words say which of the three this is.
            Label(message, systemImage: "exclamationmark.triangle")
                .font(TypeScale.label).foregroundStyle(palette.warning).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .ready(let plan):
            VStack(alignment: .leading, spacing: 12) {
                segmentationGrid(SegmentationGrid(plan.summary))
                limits(Limits(plan.summary))
                findingList(plan.findings(verbose: model.settings.verbose), count: plan.all.count)
            }
        }
    }

    /// The gauges are Advanced's question: how close a figure sits to a wall it has not hit. What
    /// the planner refused is nobody's option, so the refusals outlive the block they sit under
    /// and are said on either face -- a note that would be dropped is not a detail to opt into.
    @ViewBuilder
    private func limits(_ limits: Limits) -> some View {
        let refusals = limits.exceeded.flatMap(\.warnings)
        if model.mode == .advanced || !refusals.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if model.mode == .advanced { gauges(limits) }

                ForEach(refusals, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(TypeScale.label).foregroundStyle(palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Five rows, whatever the plan holds: a limit left out reads as a limit there is no need to
    /// think about. Amber and red differ by symbol as well as colour.
    private func gauges(_ limits: Limits) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Limits.heading).font(.caption).fontWeight(.medium)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(limits.gauges) { gauge in
                    HStack(spacing: AppLayout.labelGap) {
                        Text(gauge.name)
                            .font(.caption)
                            .frame(width: AppLayout.limitNameWidth, alignment: .leading)
                        Text(gauge.figure)
                            .font(TypeScale.value)
                            .frame(width: AppLayout.limitFigureWidth, alignment: .trailing)
                        if let symbol = style(gauge.status).symbol {
                            Image(systemName: symbol).font(.caption2)
                        }
                        if let site = gauge.site {
                            Text(site).font(TypeScale.label).foregroundStyle(palette.mutedInk)
                        }
                    }
                    .foregroundStyle(style(gauge.status).colour)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Approaching and exceeding differ by symbol as well as colour, so the two are told apart
    /// without relying on colour alone.
    private func style(_ status: Limits.Status) -> (colour: Color, symbol: String?) {
        switch status {
        case .within: return (.primary, nil)
        case .near: return (.orange, "exclamationmark.circle")
        case .over: return (.red, "exclamationmark.triangle")
        }
    }

    private func segmentationGrid(_ grid: SegmentationGrid) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What the import will lay down").font(.caption).fontWeight(.medium)
            Text(grid.header).font(TypeScale.label).foregroundStyle(palette.mutedInk)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: AppLayout.gridOrigin, height: 1)
                    HStack(spacing: AppLayout.cellSpacing) {
                        ForEach(grid.columns, id: \.self) { column in
                            Text("\(column)")
                                .font(TypeScale.smallValue).foregroundStyle(.tertiary)
                                .frame(width: AppLayout.cellWidth)
                        }
                    }
                }
                ForEach(grid.rows, id: \.track) { segmentationRow($0) }
            }

            Text(SegmentationGrid.legend).font(TypeScale.smallValue).foregroundStyle(
                palette.mutedInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func segmentationRow(_ row: SegmentationGrid.Row) -> some View {
        HStack(spacing: 0) {
            rowHead(
                readout: row.readout, name: row.name, isDrum: row.isDrum, dimmed: row.isEmpty
            )
            .help(row.detail)
            Color.clear.frame(width: AppLayout.labelGap, height: 1)
            HStack(spacing: AppLayout.cellSpacing) {
                ForEach(row.cells, id: \.pattern) { segmentationSlot($0, track: row.track) }
            }
        }
        .padding(.bottom, 4)
        // Under the cells for the reason the Chain rail is: a rail behind them would band.
        .overlay(alignment: .bottomLeading) { rails(row.runs, track: row.track) }
    }

    private func segmentationSlot(_ cell: SegmentationGrid.Cell, track: Int) -> some View {
        let fill = slotFill(
            track: track, notes: cell.noteCount, steps: cell.stepCount, isEmpty: cell.isEmpty)
        let ink = DeviceColor.ink(on: fill)
        return Text(cell.label)
            .font(TypeScale.smallValue)
            .foregroundStyle(ink)
            .opacity(cell.isEmpty ? 0.55 : 1)
            .frame(width: AppLayout.cellWidth, height: AppLayout.cellHeight)
            .background(slotBackground(fill: fill, ink: ink, steps: cell.stepCount))
            .help(cell.detail)
    }

    /// Where the planner put each source track, for the pickers to show as their automatic answer.
    /// Empty while a plan is in flight, which leaves a picker reading "Automatic" on its own.
    private func placements(_ state: SegmentationState) -> [Int: String] {
        guard case .ready(let plan) = state else { return [:] }
        return SegmentationGrid.placements(plan.summary)
    }

    /// Unscrolled, like ``grid(_:selection:length:)``: the staged view already scrolls.
    private func trackList(
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

            if let count = selection.countLine {
                Text(count).font(TypeScale.label).foregroundStyle(palette.mutedInk)
            }

            // Ticking past the device's four is flagged, not refused, so Convert stays enabled.
            if let overflow = selection.overflowNote {
                Label(overflow, systemImage: "exclamationmark.triangle")
                    .font(TypeScale.label).foregroundStyle(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = list.note(verbose: model.settings.verbose) {
                Text(note).font(TypeScale.label).foregroundStyle(palette.mutedInk)
            }

            Text(SourceTrackList.legend).font(TypeScale.smallValue).foregroundStyle(
                palette.mutedInk)
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
                "",
                isOn: Binding(
                    get: { ticked }, set: { _ in model.toggle(sourceTrack: row.number) })
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: AppLayout.trackTickWidth, alignment: .leading)
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
            destinationPicker(row, destination: destination, placement: placement)
                .frame(width: AppLayout.trackDestinationWidth, alignment: .leading)
        }
        .opacity(row.isEmpty ? 0.6 : 1)
        .contentShape(Rectangle())
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
                "",
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
    private func badge(_ badge: SourceTrackList.Badge?) -> some View {
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

    /// Not scrolled: the staged view already scrolls, and a scroller inside one traps the wheel.
    private func grid(_ grid: PatternGrid, selection: GridSelection, length: ExportLength)
        -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            Text(grid.header).font(TypeScale.label).foregroundStyle(palette.mutedInk)

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
                Text(line).font(TypeScale.label).foregroundStyle(palette.mutedInk)
            }

            Text(PatternGrid.legend).font(TypeScale.smallValue).foregroundStyle(palette.mutedInk)
            Text(GridSelection.legend).font(TypeScale.smallValue).foregroundStyle(palette.mutedInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func columnHeader(_ column: Int, state: GridSelection.Tick) -> some View {
        Button {
            model.toggle(pattern: column)
        } label: {
            Text("\(column)")
                .font(TypeScale.smallValue)
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
                    rowHead(
                        readout: row.readout, name: row.name, isDrum: row.isDrum,
                        struck: state == .off, dimmed: state != .on
                    )
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
            .overlay(alignment: .bottomLeading) { rails(row.runs, track: row.track) }

            if let chain = row.chainDetail {
                Text(chain)
                    .font(TypeScale.smallValue).foregroundStyle(palette.mutedInk)
                    .padding(.leading, AppLayout.gridOrigin)
            }
        }
    }

    /// A chain that jumps gets no bar; the caption says the order instead. The rail is the only
    /// place Chain membership shows: inside a cell it would fight the content channel.
    private func rails(_ runs: [AppLayout.Rail], track: Int) -> some View {
        ForEach(runs.indices, id: \.self) { index in
            Capsule()
                .fill(DeviceColor.track(track))
                .frame(width: runs[index].width, height: AppLayout.railHeight)
                .offset(x: runs[index].x)
        }
    }

    /// The content channel. Blended over the ground rather than drawn translucent, so the ink can
    /// be chosen from what the eye will actually see; a slot that holds anything keeps the floor,
    /// which is what lets a held pattern with every step off still read as held.
    private func slotFill(track: Int, notes: Int, steps: Int, isEmpty: Bool) -> Color {
        guard !isEmpty else { return palette.inert }
        let density = max(Density.opacity(notes: notes, steps: steps), Density.floor)
        return DeviceColor.track(track).over(palette.ground, alpha: density)
    }

    /// The fill with the length rule on its bottom edge, clipped so the rule follows the corner.
    private func slotBackground(fill: Color, ink: Color, steps: Int) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: AppLayout.cellRadius).fill(fill)
            Rectangle()
                .fill(ink)
                .frame(
                    width: AppLayout.lengthRuleWidth(steps: steps),
                    height: AppLayout.lengthRuleHeight)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppLayout.cellRadius))
    }

    /// An em dash means the slot holds nothing; `0` means it holds notes with every step off.
    private func slot(_ cell: PatternGrid.Cell, track: Int, selection: GridSelection) -> some View {
        let ticked = selection.isTicked(track: track, pattern: cell.pattern)
        let fill = slotFill(
            track: track, notes: cell.noteCount, steps: cell.stepCount, isEmpty: cell.isEmpty)
        let ink = DeviceColor.ink(on: fill)
        return Button {
            model.toggle(track: track, pattern: cell.pattern)
        } label: {
            Text(cell.label)
                .font(TypeScale.value)
                // Shrunk rather than truncated: a count reading "1…" would be worse than small.
                .lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(ink)
                .opacity(cell.isEmpty ? 0.55 : 1)
                .frame(width: AppLayout.cellWidth, height: AppLayout.cellHeight)
                .background(
                    slotBackground(
                        fill: fill, ink: ink, steps: cell.isEmpty ? 0 : cell.stepCount)
                )
                // The whole export channel: solid exports, dashed does not, and nothing else about
                // the cell moves with the tick.
                .overlay {
                    RoundedRectangle(cornerRadius: AppLayout.cellRadius)
                        .strokeBorder(
                            ink.opacity(0.55),
                            style: ticked
                                ? StrokeStyle(lineWidth: 1)
                                : StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(cell.detail + (ticked ? "" : " · unticked, so it will not be exported"))
    }

    /// The pattern readout in its well, the track name, and the drum badge. Both grids draw it, so
    /// the two read as the same object seen in each direction.
    private func rowHead(
        readout: String, name: String, isDrum: Bool, struck: Bool = false, dimmed: Bool = false
    ) -> some View {
        HStack(spacing: AppLayout.labelGap) {
            Text(readout)
                .font(TypeScale.readout).foregroundStyle(palette.bandInk)
                .frame(width: AppLayout.wellWidth, height: AppLayout.cellHeight)
                .background(
                    RoundedRectangle(cornerRadius: AppLayout.wellRadius).fill(palette.well))
            Text(name)
                .font(.caption).fontWeight(.medium).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(dimmed ? palette.mutedInk : palette.ink)
                .strikethrough(struck)
                .frame(width: AppLayout.rowNameWidth, alignment: .leading)
            Group {
                if isDrum {
                    Text("Drum")
                        .font(TypeScale.smallLabel).lineLimit(1)
                        .foregroundStyle(palette.mutedInk)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(palette.inert))
                }
            }
            .frame(width: AppLayout.rowBadgeWidth, alignment: .leading)
        }
        .frame(width: AppLayout.labelWidth, alignment: .leading)
    }

    @ViewBuilder
    private func dryRunPreview(_ preview: Outcome) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                preview.previewLine,
                systemImage: preview.failed ? "exclamationmark.triangle" : "eye"
            )
            .font(TypeScale.sectionTitle)
            .foregroundStyle(preview.failed ? palette.warning : palette.mutedInk)

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
                    if let folder = outcome.folder { landedIn(folder) }
                    if outcome.written.count > 1 || outcome.folder != nil {
                        writtenFiles(outcome.written)
                    }

                    Text(outcome.headline).font(.callout).textSelection(.enabled)

                    if let note = outcome.note {
                        Text(note).font(TypeScale.label).foregroundStyle(palette.mutedInk)
                    }

                    findings(outcome)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
    private func findings(_ outcome: Outcome) -> some View {
        findingList(outcome.findings(verbose: model.settings.verbose), count: outcome.all.count)
    }

    /// Shared so a plan's findings and a run's read alike; the plan raises them first.
    @ViewBuilder
    private func findingList(_ findings: [String], count: Int) -> some View {
        if count > 0 {
            DisclosureGroup("\(count) finding(s)") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(findings, id: \.self) { finding in
                        Text(finding).font(.caption).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
