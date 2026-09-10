import AppKit
import KSPKit
import KSPMIDI
import KSPRun
import SwiftUI

struct DropView: View {
    @Bindable var model: AppModel
    @State private var targeted = false
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            band

            VStack(spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(AppLayout.mainPadding)

            Divider()
            actionBar
        }
        .frame(
            minWidth: AppLayout.minimumWindowWidth, maxWidth: .infinity,
            minHeight: AppLayout.minimumWindowHeight, maxHeight: .infinity
        )
        .background(palette.ground)
        .foregroundStyle(palette.ink)
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
            Spacer()
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
        case .reading(let slot):
            Text("Project \(slot)").font(TypeScale.bandTitle)
            Text("KeyStep Pro → project file")
                .font(TypeScale.label).foregroundStyle(palette.bandInk.opacity(0.65))
        case .done(let outcome):
            // The glyph carries the outcome; the colour only agrees with it. Track 2 is orange and
            // Track 4 is red, so a status hue is never enough on its own.
            Image(systemName: outcome.failed ? StatusMark.error : StatusMark.success)
                .foregroundStyle(outcome.failed ? palette.error : palette.success)
            Text(outcome.resultLine).font(TypeScale.bandTitle).lineLimit(1)
        }
    }

    /// Where the result lands and the button that writes it, across the foot of the window: a
    /// commit action belongs beside what it acts on, which is not a pane's height above it.
    private var actionBar: some View {
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
        default:
            EmptyView()
        }
    }

    /// The folder gives way first: the name is what the user typed, and the head of a path is
    /// the part they can spare.
    private func landingRow(_ landing: Landing, kind: FolderKind) -> some View {
        HStack(spacing: 8) {
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

            Button("Choose…") { model.choose(kind) }
                .controlSize(.small)
        }
    }

    /// The action slot, which is never empty while an action can be taken: Convert while a file
    /// is staged, the way back once one is written, and the way in while nothing is.
    @ViewBuilder
    private var action: some View {
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
            Button(outcome.againLabel) { model.reset() }
        case .idle:
            // Return belongs to the device card's own button here, so this takes no default
            // action: two of them in one phase is a coin toss over which one Return reaches.
            Button("Open…") { model.open() }
        default:
            EmptyView()
        }
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

    /// The controls that reshape the export, in the section that shows what is being exported.
    /// Every one of them changes the .mid about to be written, which is why it sits here and not
    /// in a column of its own: a reader should never have to guess which controls reach the file.
    private var exportOptions: some View {
        optionBand {
            Picker("", selection: $model.settings.splitPerPattern) {
                Text("One file for everything").tag(false)
                Text("One file per pattern slot").tag(true)
            }
            .labelsHidden()
            .frame(width: AppLayout.splitPickerWidth)
            .onChange(of: model.settings.splitPerPattern) { model.discardPreview() }
            .help("One file per pattern slot holds one slot each and starts at its own bar 1.")

            Picker("Step Skip", selection: $model.settings.stepSkip) {
                ForEach(Settings.StepSkip.allCases) { Text($0.label).tag($0) }
            }
            .frame(width: AppLayout.stepSkipPickerWidth)
            .onChange(of: model.settings.stepSkip) { model.discardPreview() }
            .help(
                "Auto expands the device's 16/32/48/64 cycle to four passes when a note "
                    + "skips part of it; 1 flattens the cycle to a single pass that plays "
                    + "every note whatever its mask. This is the device's own cycle, not "
                    + "copies of the export.")

            Stepper(value: $model.settings.repeatCount, in: Settings.repeatRange) {
                Text("Repeat ×\(model.settings.repeatCount)")
            }
            .frame(width: AppLayout.repeatStepperWidth)
            .onChange(of: model.settings.repeatCount) { model.discardPreview() }
            .help(
                "Lay the whole export down this many times end to end. This one is not the "
                    + "cycle beside it: it exists only in the .mid, and the device stores no "
                    + "such count, so no repeat of it can be written back to a project.")

            bandDivider

            keeps(
                velocity: \.replaceVelocity,
                velocityNote: "Untick to write every note and trigger at the fresh-note velocity, "
                    + "\(MIDIExport.defaultFlatVelocity), instead of the one it stores.",
                swing: \.replaceSwing,
                swingNote: "Untick to put every step on a flat grid instead of applying the "
                    + "delay the pattern's swing asks for.",
                timeShift: \.replaceTimeShift,
                timeShiftNote: "Untick to put every step on the grid instead of applying the "
                    + "offset the note stores.")
        }
    }

    /// The same band on the way in, and the reason the two are written apart: swing here means
    /// fitting the source's groove, not applying a delay the project already stores.
    private var importOptions: some View {
        optionBand {
            Picker("Drums", selection: $model.drumChoice) {
                ForEach(model.drumChoices) { Text($0.label).tag($0) }
            }
            .frame(width: AppLayout.drumsPickerWidth)
            .onChange(of: model.drumChoice) { model.discardPreview() }
            .help(
                "Automatic searches one channel for a kit; None imports every track melodically. "
                    + "Sending a source track to Drums in the list above names one outright.")

            // Offered only while a channel is what the import searches: under None nothing is
            // searched, and a named source track is found without one.
            if model.drumSense.designation == .auto {
                Stepper(value: $model.settings.drumChannel, in: Settings.drumChannelRange) {
                    Text("Channel \(model.settings.drumChannel)")
                }
                .frame(width: AppLayout.drumChannelStepperWidth)
                .onChange(of: model.settings.drumChannel) { model.discardPreview() }
                .help(
                    "The source track sitting wholly on this channel becomes the drum track. "
                        + "General MIDI puts a kit on 10, but a DAW can export one anywhere.")
            }

            bandDivider

            keeps(
                velocity: \.ignoreVelocity,
                velocityNote: "Untick to write every note and trigger at the fresh-note velocity, "
                    + "\(MIDIExport.defaultFlatVelocity), instead of the source's own.",
                swing: \.ignoreSwing,
                swingNote: "Untick to leave every pattern straight at "
                    + "\(Constants.swingRangePercent.min)% instead of fitting it to the "
                    + "source's groove.",
                timeShift: \.ignoreTimeShift,
                timeShiftNote: "Untick to quantise every note hard to its step at a time shift "
                    + "of 0 instead of giving it the leftover it would otherwise keep.")
        }
    }

    /// The three substitutions, put the way the reader thinks about them rather than the way the
    /// runner takes them: a ticked box keeps what the file holds, and unticking one writes the
    /// device's own default over it.
    @ViewBuilder
    private func keeps(
        velocity: WritableKeyPath<Settings, Bool>, velocityNote: String,
        swing: WritableKeyPath<Settings, Bool>, swingNote: String,
        timeShift: WritableKeyPath<Settings, Bool>, timeShiftNote: String
    ) -> some View {
        Text("Keep")
            .foregroundStyle(palette.mutedInk)
            .frame(width: AppLayout.keepLabelWidth, alignment: .leading)
        keep("Velocity", velocity, help: velocityNote, width: AppLayout.keepWidths[0])
        keep("Swing", swing, help: swingNote, width: AppLayout.keepWidths[1])
        keep("Time Shift", timeShift, help: timeShiftNote, width: AppLayout.keepWidths[2])
    }

    private func keep(
        _ title: String, _ substituted: WritableKeyPath<Settings, Bool>, help: String,
        width: CGFloat
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { !model.settings[keyPath: substituted] },
                set: {
                    model.settings[keyPath: substituted] = !$0
                    model.discardPreview()
                })
        )
        .frame(width: width, alignment: .leading)
        .help(help)
    }

    /// One row on its own plate under the thing it changes, so the section reads as source and
    /// then what may be done to it rather than as two unrelated blocks.
    private func optionBand<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: AppLayout.bandGap) {
            content()
            Spacer(minLength: 0)
        }
        .font(TypeScale.label)
        .controlSize(.small)
        .toggleStyle(.checkbox)
        .padding(.vertical, AppLayout.bandPadding)
        .padding(.horizontal, AppLayout.bandPadding + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppLayout.cardRadius).fill(palette.surface))
    }

    private var bandDivider: some View {
        Divider().frame(height: AppLayout.bandDividerHeight)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            idle
        case .staged(let staged):
            self.staged(staged)
        case .working(let filename):
            working(filename)
        case .reading:
            reading
        case .done(let outcome):
            done(outcome)
        }
    }

    /// The instrument at rest rather than a system dialog: the map is the app's own object, and
    /// an empty one says what the window is for -- four tracks, sixteen slots, drop something in.
    private var idle: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            restingMap(playhead: nil)
                .overlay { prompt }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "Drop a MIDI file or a KeyStep Pro project here. "
                        + "Four tracks of sixteen pattern slots.")
            Spacer(minLength: 0)
            deviceCard
        }
    }

    /// On a plate rather than straight over the cells: the map is dim, but a line of type over
    /// sixteen of anything is still type over a texture.
    private var prompt: some View {
        Text("Drop a MIDI file or a KeyStep Pro project")
            .font(.title3)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: AppLayout.cardRadius).fill(palette.ground))
    }

    /// The chase, which is the only thing in the app that moves. Its clock is the view's own, so
    /// the conversion is never told the animation exists and cannot be made to wait on it; the
    /// floor lives in ``Chase/holdOff``, before the first column rather than after the last.
    @ViewBuilder
    private func working(_ filename: String) -> some View {
        if reduceMotion {
            ProgressView("Converting \(filename)…")
        } else {
            Playhead { column in restingMap(playhead: column) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Converting \(filename)…")
        }
    }

    /// Idle and converting are one object: the empty map in the track colours, at an intensity
    /// under anything a slot holding notes takes. `playhead` lights a column white, which is what
    /// the device lights the step it is playing.
    private func restingMap(playhead: Int?) -> some View {
        VStack(alignment: .leading, spacing: AppLayout.cellSpacing) {
            ForEach(1...AppLayout.rowCount, id: \.self) { track in
                HStack(spacing: 0) {
                    rowHead(
                        readout: patternReadout(nil), name: "Track \(track)", isDrum: false,
                        dimmed: true)
                    Color.clear.frame(width: AppLayout.labelGap, height: 1)
                    HStack(spacing: AppLayout.cellSpacing) {
                        ForEach(0..<AppLayout.columnCount, id: \.self) { column in
                            restingSlot(track: track, isPlayhead: column == playhead)
                        }
                    }
                }
            }
        }
    }

    /// The rule around every cell is what draws the map while it holds nothing, and what keeps
    /// the white step legible on the standard unit's off-white ground.
    private func restingSlot(track: Int, isPlayhead: Bool) -> some View {
        let hue = DeviceColor.track(track).over(
            palette.ground, alpha: targeted ? Density.restingTargeted : Density.resting)
        return RoundedRectangle(cornerRadius: AppLayout.cellRadius)
            .fill(isPlayhead ? DeviceColor.now : hue)
            .frame(width: AppLayout.cellWidth, height: AppLayout.cellHeight)
            .overlay {
                RoundedRectangle(cornerRadius: AppLayout.cellRadius)
                    .strokeBorder(palette.rule, lineWidth: 1)
            }
    }

    /// The other way a project reaches the app: off the device rather than out of a file. It sits
    /// on the idle pane because it is an alternative to the drop above it, not a mode of its own.
    private var deviceCard: some View {
        let plan = model.deviceReadPlan
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Read from the KeyStep Pro")

            slotPicker

            NameField(
                prompt: DeviceRead.defaultStem(slot: model.slot), text: $model.readName,
                palette: palette)

            VStack(alignment: .leading, spacing: 2) {
                Text("Will be written to").font(TypeScale.label).foregroundStyle(palette.mutedInk)
                Text(plan.target.path).font(.callout).textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
            }

            if let note = plan.note {
                Text(note).font(TypeScale.label).foregroundStyle(palette.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Also write the MIDI file", isOn: $model.alsoMidi)
                    .toggleStyle(.checkbox)
                    .help("The same .mid that converting the project afterwards would make.")
                if let note = model.deviceMIDINote {
                    Text(note).font(TypeScale.label).foregroundStyle(palette.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("Read project \(model.slot)") { Task { await model.read() } }
                    .keyboardShortcut(.defaultAction)
                    .help(
                        "The device is read over USB and needs no password. A project is read "
                            + "as it was saved, so save any panel edits first.")
            }
        }
        .padding(AppLayout.deviceCardPadding)
        .frame(width: AppLayout.deviceCardWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppLayout.cardRadius).fill(palette.surface))
    }

    /// The device's sixteen on the pattern map's own metrics. The chosen one is a lit readout
    /// among unlit ones and the Read button names it, so no hue carries the choice.
    private var slotPicker: some View {
        HStack(spacing: AppLayout.cellSpacing) {
            ForEach(Array(DeviceRead.slots), id: \.self) { slot in slotCell(slot) }
        }
        .frame(width: AppLayout.slotPickerWidth, alignment: .leading)
    }

    private func slotCell(_ slot: Int) -> some View {
        let chosen = slot == model.slot
        return Button {
            model.slot = slot
        } label: {
            Text(patternReadout(slot))
                .font(TypeScale.readout)
                .foregroundStyle(chosen ? palette.bandInk : palette.mutedInk)
                .frame(width: AppLayout.cellWidth, height: AppLayout.slotCellHeight)
                .background(
                    RoundedRectangle(cornerRadius: AppLayout.cellRadius)
                        .fill(chosen ? palette.well : palette.inert)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AppLayout.cellRadius)
                        .strokeBorder(palette.ink.opacity(chosen ? 0.55 : 0), lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Project \(slot)")
        .accessibilityLabel("Project \(slot)")
    }

    /// The walk reports no position, so the progress is the system's own indeterminate view --
    /// with the one instruction that matters while it runs.
    private var reading: some View {
        VStack(spacing: 8) {
            ProgressView("Reading from the KeyStep Pro…")
            Text("Leave the device alone until it finishes.")
                .font(TypeScale.label).foregroundStyle(palette.mutedInk)
        }
    }

    private func staged(_ staged: AppModel.Staged) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // A refused file has no name to give, nowhere to land and nothing to run, so
                // the promise goes whole rather than standing above its own refusal.
                if !staged.isUnreadable { outputPlan(staged.job) }

                summary(staged)

                if let preview = staged.preview {
                    Divider()
                    dryRunPreview(preview)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: staged.id) { await model.summarise() }
        .task(id: model.segmentationKey) { await model.segment() }
        .task(id: model.arrangementKey) { await model.arrange() }
    }

    /// The name and what naming it costs. Where it lands is in the action bar, beside the button
    /// that writes it.
    @ViewBuilder
    private func outputPlan(_ job: Job) -> some View {
        let plan = model.plan(for: job)

        NameField(prompt: "Name", text: $model.name, palette: palette)
            .onChange(of: model.name) { model.discardPreview() }
            .help(nameHelp(plan))

        if let note = plan.note {
            Text(note).font(TypeScale.label).foregroundStyle(palette.mutedInk)
        }

        Divider()
    }

    /// What was refused, said once: the sentence, then the file it is about. The path is the
    /// quieter of the two because it answers "which file", not "what now".
    private func refusal(_ failure: ReadFailure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(failure.headline, systemImage: StatusMark.error)
                .font(TypeScale.label).foregroundStyle(palette.warning)
                .fixedSize(horizontal: false, vertical: true)
            Text(failure.path)
                .font(TypeScale.smallLabel).foregroundStyle(palette.mutedInk)
                .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func summary(_ staged: AppModel.Staged) -> some View {
        switch staged.summary {
        case .loading:
            ProgressView(staged.job.isProject ? "Reading the project…" : "Reading the MIDI file…")
                .controlSize(.small)
        case .failed(let failure):
            refusal(failure)
        case .project(let summary):
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Source")
                grid(
                    PatternGrid(summary), selection: staged.selection,
                    length: ExportLength(summary, selection: staged.selection))
                exportOptions
                Divider()
                sectionHeader("Result")
                arrangement(staged.arrangement)
            }
        case .song(let summary):
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("Source")
                trackList(
                    SourceTrackList(
                        summary, drums: model.drumSense, selection: staged.sourceSelection),
                    selection: staged.sourceSelection,
                    placements: placements(staged.segmentation))
                importOptions
                Divider()
                sectionHeader("Result")
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
                findingList(
                    plan.rows(verbose: model.verbose), count: plan.allRows.count)
            }
        }
    }

    /// Feedback, never an option: whether a loop fits the device's walls is the most useful thing
    /// on screen for a reader who does not know the hardware yet, so both faces show it. Advanced
    /// adds controls; it never takes feedback away.
    private func limits(_ limits: Limits) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            gauges(limits)

            ForEach(limits.exceeded.flatMap(\.warnings), id: \.self) { warning in
                HStack(alignment: .firstTextBaseline, spacing: AppLayout.labelGap) {
                    Image(systemName: StatusMark.error).font(.caption2)
                        .frame(width: AppLayout.findingGlyphWidth, alignment: .leading)
                    figured(warning, font: TypeScale.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(palette.error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The answer, then the five figures it was read off. A limit left out reads as a limit there
    /// is no need to think about, so all five are drawn whatever the plan holds.
    private func gauges(_ limits: Limits) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Limits.heading).font(.caption).fontWeight(.medium)
                    .foregroundStyle(palette.mutedInk)
                verdictLine(limits.verdict)
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(limits.gauges) { gauge in
                    HStack(spacing: AppLayout.labelGap) {
                        Text(gauge.name)
                            .font(.caption)
                            .frame(width: AppLayout.limitNameWidth, alignment: .leading)
                        meter(gauge)
                        Text(gauge.figure)
                            .font(TypeScale.value)
                            .frame(width: AppLayout.limitFigureWidth, alignment: .trailing)
                        Group {
                            if let symbol = style(gauge.status).symbol {
                                Image(systemName: symbol).font(.caption2)
                            }
                        }
                        .frame(width: AppLayout.findingGlyphWidth, alignment: .leading)
                        if let site = limits.shownSite(gauge) {
                            figured(site, font: TypeScale.label)
                                .foregroundStyle(palette.mutedInk)
                                .frame(width: AppLayout.limitSiteWidth, alignment: .leading)
                        }
                    }
                    .foregroundStyle(style(gauge.status).colour)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Quantity only: how much of the wall this figure uses, so a lit segment means the same thing
    /// on every row. The cap is the ceiling the segments fill toward, and it never moves.
    private func meter(_ gauge: Limits.Gauge) -> some View {
        let lit = AppLayout.meterFill(used: gauge.used, limit: gauge.limit)
        return HStack(spacing: 0) {
            HStack(spacing: AppLayout.meterSegmentGap) {
                ForEach(0..<AppLayout.meterSegmentCount, id: \.self) { segment in
                    RoundedRectangle(cornerRadius: AppLayout.meterSegmentRadius)
                        .fill(segment < lit ? style(gauge.status).colour : palette.rule)
                        .frame(
                            width: AppLayout.meterSegmentWidth, height: AppLayout.meterHeight)
                }
            }
            Spacer(minLength: AppLayout.meterCapGap)
            RoundedRectangle(cornerRadius: AppLayout.meterSegmentRadius)
                .fill(palette.mutedInk)
                .frame(width: AppLayout.meterCapWidth, height: AppLayout.meterHeight)
        }
        .frame(width: AppLayout.meterWidth, alignment: .leading)
    }

    /// Marked in all three states, where a meter marks only a refusal: this line carries no
    /// quantity of its own, so with the colour removed the glyph is all that is left to read the
    /// status off -- rule 2.
    private func verdictLine(_ verdict: Limits.Verdict) -> some View {
        let mark = self.mark(verdict.status)
        return Label {
            figured(verdict.text, font: TypeScale.label)
        } icon: {
            Image(systemName: mark.symbol).font(.caption)
        }
        .foregroundStyle(mark.colour)
    }

    private func mark(_ status: Limits.Status) -> (colour: Color, symbol: String) {
        switch status {
        case .within: return (palette.success, StatusMark.success)
        case .near: return (palette.warning, StatusMark.warning)
        case .over: return (palette.error, StatusMark.error)
        }
    }

    /// A refusal is the only one of the three marked: the meter already says how close a figure
    /// sits, so approaching a wall is emphasis on a quantity rather than a status. Passing one is
    /// a status, and it takes the colour and the glyph together -- rule 2.
    private func style(_ status: Limits.Status) -> (colour: Color, symbol: String?) {
        switch status {
        case .within: return (palette.ink, nil)
        case .near: return (palette.warning, nil)
        case .over: return (palette.error, StatusMark.error)
        }
    }

    /// Rule 2 again, on a finding rather than a gauge: the glyph and the order carry severity and
    /// the colour only agrees with them.
    private func style(_ severity: Severity) -> (colour: Color, symbol: String) {
        severity == .error
            ? (palette.error, StatusMark.error) : (palette.warning, StatusMark.warning)
    }

    /// A failure line names the file that failed, and a filename's digits are not figures: the
    /// `2` of `Take2.wav` is part of a name, not a value the device shows.
    @ViewBuilder
    private func headline(_ outcome: Outcome, font: Font, figures: Font) -> some View {
        if outcome.failed {
            Text(outcome.headline).font(font)
        } else {
            figured(outcome.headline, font: font, figures: figures)
        }
    }

    /// Rule 3, applied to prose the core wrote: every figure in it set in SF Mono. Concatenated
    /// rather than laid out, so the line still wraps and still selects as one piece of text.
    private func figured(_ text: String, font: Font, figures: Font = TypeScale.value) -> Text {
        Figures.split(text).reduce(Text(verbatim: "")) { built, run in
            built + Text(run.text).font(run.isFigure ? figures : font)
        }
    }

    private func segmentationGrid(_ grid: SegmentationGrid) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
            .foregroundStyle(cell.isEmpty ? palette.mutedInk : ink)
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
    /// No selection is the read-only preview: every slot as it stands, and nothing to click.
    private func grid(_ grid: PatternGrid, selection: GridSelection?, length: ExportLength?)
        -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            Text(grid.header).font(TypeScale.label).foregroundStyle(palette.mutedInk)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: AppLayout.gridOrigin, height: 1)
                    HStack(spacing: AppLayout.cellSpacing) {
                        ForEach(grid.columns, id: \.self) { column in
                            columnHeader(column, selection: selection)
                        }
                    }
                }
                ForEach(grid.rows, id: \.track) { trackRow($0, selection: selection) }
            }

            if let warning = length?.warning {
                Text(warning).font(TypeScale.label).foregroundStyle(palette.mutedInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Read-only, and relaid whenever the ticks or a setting move it: where the export puts each
    /// Pattern in time, which the map above cannot say because its columns are all one width.
    @ViewBuilder
    private func arrangement(_ state: ArrangementState) -> some View {
        switch state {
        case .loading:
            ProgressView("Laying out the patterns…").controlSize(.small)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(TypeScale.label).foregroundStyle(palette.warning).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .ready(let summary):
            lanes(ArrangeLanes(summary))
        }
    }

    private func lanes(_ lanes: ArrangeLanes) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lanes.header).font(TypeScale.label).foregroundStyle(palette.mutedInk)

            VStack(alignment: .leading, spacing: AppLayout.laneSpacing) {
                ForEach(lanes.lanes, id: \.track) { lane($0, boundaries: lanes.boundaries) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The row head the map draws, so a lane and the row above it read as one track seen twice.
    private func lane(_ lane: ArrangeLanes.Lane, boundaries: [ArrangeLanes.Boundary]) -> some View {
        HStack(spacing: 0) {
            rowHead(
                readout: lane.readout, name: lane.name, isDrum: lane.isDrum, dimmed: lane.isEmpty
            )
            .help(lane.detail)
            Color.clear.frame(width: AppLayout.labelGap, height: 1)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(palette.surface)
                ForEach(lane.regions, id: \.slot) { region($0, track: lane.track) }
                // Over the regions: a boundary is where one Pattern gives way to the next, and a
                // region drawn short of it would otherwise hide the line that says so.
                ForEach(boundaries, id: \.slot) { boundary in
                    Rectangle()
                        .fill(palette.rule)
                        .frame(width: AppLayout.boundaryWidth, height: AppLayout.laneHeight)
                        .offset(x: boundary.x)
                }
            }
            .frame(width: AppLayout.axisWidth, height: AppLayout.laneHeight, alignment: .topLeading)
            .clipped()
        }
    }

    /// Fill is identity and held-or-empty; the marks are the rhythm. Density stays in the map's
    /// cells above, which is the one place a count per step is known.
    private func region(_ region: ArrangeLanes.Region, track: Int) -> some View {
        let fill =
            region.isEmpty
            ? palette.inert : DeviceColor.track(track).over(palette.ground, alpha: Density.floor)
        let ink = DeviceColor.ink(on: fill)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: AppLayout.regionRadius).fill(fill)
            if region.showsMarks {
                ForEach(region.marks.indices, id: \.self) { index in
                    // Drawn in the ink rather than the hue: the block already says which track
                    // this is, and a mark has to stay legible on either face. Its width is taken
                    // as given -- widening one here would undo the hold at the region's edge.
                    Rectangle()
                        .fill(ink.opacity(AppLayout.markInkOpacity))
                        .frame(width: region.marks[index].width, height: AppLayout.markHeight)
                        .offset(x: region.marks[index].x, y: region.marks[index].y)
                }
            }
            if region.showsLabel {
                Text(region.label)
                    .font(TypeScale.smallValue)
                    .foregroundStyle(region.isEmpty ? palette.mutedInk : ink)
                    .padding(.leading, AppLayout.regionLabelInset)
            }
        }
        .frame(width: region.width, height: AppLayout.laneHeight, alignment: .topLeading)
        .clipped()
        .offset(x: region.x)
        .help(region.detail)
    }

    @ViewBuilder
    private func tickable<Label: View>(_ label: Label, help: String, toggle: (() -> Void)?)
        -> some View
    {
        if let toggle {
            Button(action: toggle) {
                label.contentShape(Rectangle())
            }
            .buttonStyle(TickStyle())
            .help(help)
        } else {
            label.help(help)
        }
    }

    private func columnHeader(_ column: Int, selection: GridSelection?) -> some View {
        let state = selection?.state(ofPattern: column) ?? .on
        let toggle: (() -> Void)? =
            selection == nil ? nil : { model.toggle(pattern: column) }
        let help =
            toggle == nil
            ? "Pattern slot \(column)"
            : (state == .on
                ? "Pattern slot \(column) — click to untick it on every track."
                : "Pattern slot \(column) — click to tick it on every track.")
        return tickable(columnLabel(column, state: state), help: help, toggle: toggle)
    }

    private func columnLabel(_ column: Int, state: GridSelection.Tick) -> some View {
        Text("\(column)")
            .font(TypeScale.smallValue)
            .foregroundStyle(state == .on ? HierarchicalShapeStyle.secondary : .tertiary)
            .strikethrough(state == .off)
            .frame(width: AppLayout.cellWidth)
    }

    /// One track: its name, its cells, the rails joining whatever it chains, and the chain beneath.
    private func trackRow(_ row: PatternGrid.Row, selection: GridSelection?) -> some View {
        let state = selection?.state(ofTrack: row.track) ?? .on
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                trackHead(row, state: state, ticking: selection != nil)
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

    private func trackHead(_ row: PatternGrid.Row, state: GridSelection.Tick, ticking: Bool)
        -> some View
    {
        let head = rowHead(
            readout: row.readout, name: row.name, isDrum: row.isDrum, struck: state == .off,
            dimmed: state != .on)
        let help =
            ticking
            ? row.detail
                + (state == .on
                    ? " · Click to untick this whole track."
                    : " · Click to tick this whole track.")
            : row.detail
        return tickable(
            head, help: help, toggle: ticking ? { model.toggle(track: row.track) } : nil)
    }

    /// A chain that jumps gets no bar; the caption says the order instead. The rail is the only
    /// place Chain membership shows: inside a cell it would fight the content channel.
    private func rails(_ runs: [AppLayout.Rail], track: Int) -> some View {
        let color = DeviceColor.track(track)
        return ForEach(runs.indices, id: \.self) { index in
            Capsule()
                .fill(color)
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
    private func slot(_ cell: PatternGrid.Cell, track: Int, selection: GridSelection?) -> some View
    {
        let ticked = selection?.isTicked(track: track, pattern: cell.pattern) ?? true
        let toggle: (() -> Void)? =
            selection == nil ? nil : { model.toggle(track: track, pattern: cell.pattern) }
        let help =
            toggle == nil
            ? cell.detail
            : cell.detail + (ticked ? "" : " · unticked, so it will not be exported")
        return tickable(
            slotFace(cell, track: track, ticked: ticked), help: help, toggle: toggle)
    }

    private func slotFace(_ cell: PatternGrid.Cell, track: Int, ticked: Bool) -> some View {
        let fill = slotFill(
            track: track, notes: cell.noteCount, steps: cell.stepCount, isEmpty: cell.isEmpty)
        let ink = DeviceColor.ink(on: fill)
        return Text(cell.label)
            .font(TypeScale.value)
            // Shrunk rather than truncated: a count reading "1…" would be worse than small.
            .lineLimit(1).minimumScaleFactor(0.7)
            // An empty slot takes the muted ink rather than the fill's, so a grid of them
            // cannot shout over the two cells that actually hold something.
            .foregroundStyle(cell.isEmpty ? palette.mutedInk : ink)
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
                        ink.opacity(0.35),
                        style: ticked
                            ? StrokeStyle(lineWidth: 1)
                            : StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
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

            headline(preview, font: .caption, figures: TypeScale.value)
                .textSelection(.enabled)
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

                    headline(outcome, font: .callout, figures: TypeScale.headlineValue)
                        .textSelection(.enabled)

                    if let note = outcome.note {
                        Text(note).font(TypeScale.label).foregroundStyle(palette.mutedInk)
                    }

                    findings(outcome)

                    if let preview = model.readPreview { readBack(preview) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: model.readPreview?.project) { await model.previewRead() }
    }

    /// What the read wrote, drawn as a dropped project is drawn but with nothing to tick: the
    /// files are written already, so a selection here would decide nothing.
    @ViewBuilder
    private func readBack(_ preview: AppModel.ReadPreview) -> some View {
        Divider()
        switch preview.summary {
        case .loading:
            ProgressView("Reading the project back…").controlSize(.small)
        case .failed(let failure):
            refusal(failure)
        case .project(let summary):
            VStack(alignment: .leading, spacing: 12) {
                grid(PatternGrid(summary), selection: nil, length: nil)
                Divider()
                arrangement(preview.arrangement)
            }
        // A project never summarises as a song; a read writes nothing else.
        case .song:
            EmptyView()
        }
    }

    /// A split run names its own files, so the name reaches the folder they land in instead.
    private func nameHelp(_ plan: Conversion.Plan) -> String {
        if plan.intoFolder {
            return "This names the folder the files land in. Each file is named after the "
                + "project and the slot it holds."
        }
        return plan.job.writesMIDI
            ? "This names the .mid."
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
        findingList(outcome.rows(verbose: model.verbose), count: outcome.allRows.count)
    }

    /// Shared so a plan's findings and a run's read alike; the plan raises them first.
    @ViewBuilder
    private func findingList(_ findings: [Finding], count: Int) -> some View {
        if count > 0 {
            DisclosureGroup("\(count) finding(s)") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(findings) { finding in
                        HStack(alignment: .firstTextBaseline, spacing: AppLayout.labelGap) {
                            Image(systemName: style(finding.severity).symbol)
                                .font(.caption2)
                                .foregroundStyle(style(finding.severity).colour)
                                .frame(width: AppLayout.findingGlyphWidth, alignment: .leading)
                            figured(finding.text, font: .caption)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Where the user names what is about to be written. Drawn from the palette rather than left to
/// `.roundedBorder`, whose bezel is AppKit's and takes no palette input: a passive field has to
/// stay quieter than the ink beside it, and a fill the app never chose cannot promise that.
///
/// The ring stays the system accent, which is a user setting with accessibility weight.
private struct NameField: View {
    let prompt: String
    @Binding var text: String
    let palette: Palette
    @FocusState private var focused: Bool
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(palette.mutedInk))
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(TypeScale.label)
            .foregroundStyle(palette.ink)
            .focused($focused)
            .padding(AppLayout.fieldPadding)
            .background(
                RoundedRectangle(cornerRadius: AppLayout.fieldRadius).fill(palette.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppLayout.fieldRadius)
                    .strokeBorder(palette.rule, lineWidth: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppLayout.fieldRadius)
                    .strokeBorder(Color.accentColor, lineWidth: AppLayout.fieldRingWidth)
                    .opacity(focused && activeState == .key ? 1 : 0)
            }
    }
}

/// What says a slot, a track name or a slot number is clickable, now that no sentence under the
/// grid does: the system accent rings it under the pointer, which is what the accent is for.
private struct TickStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TickFace(configuration: configuration)
    }
}

private struct TickFace: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .opacity(configuration.isPressed ? AppLayout.pressedOpacity : 1)
            .overlay {
                RoundedRectangle(cornerRadius: AppLayout.cellRadius)
                    .strokeBorder(Color.accentColor, lineWidth: AppLayout.hoverRingWidth)
                    .opacity(hovering ? 1 : 0)
            }
            .onHover { hovering = $0 }
    }
}

/// What runs the chase. The start is this view's own state, created when the working pane appears
/// and gone when it leaves, so no clock outlives the conversion it belongs to.
private struct Playhead<Content: View>: View {
    @ViewBuilder let map: (Int?) -> Content
    @State private var start = Date()

    var body: some View {
        TimelineView(.periodic(from: start, by: Chase.step)) { context in
            map(Chase.column(after: context.date.timeIntervalSince(start)))
        }
    }
}
