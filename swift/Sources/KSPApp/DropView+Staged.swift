import AppKit
import KSPKit
import KSPMIDI
import KSPRun
import SwiftUI

/// What a dropped file looks like before it is converted.
extension DropView {
    /// The instrument at rest rather than a system dialog: the map is the app's own object, and
    /// an empty one says what the window is for -- four tracks, sixteen slots, drop something in.
    var idle: some View {
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
    var prompt: some View {
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
    func working(_ filename: String) -> some View {
        if reduceMotion {
            ProgressView("Converting \(filename)…")
        } else {
            Playhead { column in restingMap(playhead: column) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Converting \(filename)…")
        }
    }

    func staged(_ staged: AppModel.Staged) -> some View {
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
    func refusal(_ failure: ReadFailure) -> some View {
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
    func summary(_ staged: AppModel.Staged) -> some View {
        switch staged.summary {
        case .loading:
            ProgressView(staged.job.isProject ? "Reading the project…" : "Reading the MIDI file…")
                .controlSize(.small)
        case .failed(let failure):
            refusal(failure)
        case .project(let summary):
            VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                section("Source") {
                    grid(
                        PatternGrid(summary), selection: staged.selection,
                        length: ExportLength(summary, selection: staged.selection))
                    Divider()
                    exportOptions
                }
                section("Result") { arrangement(staged.arrangement) }
            }
        case .song(let summary):
            VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                section("Source") {
                    trackList(
                        SourceTrackList(
                            summary, drums: model.drumSense, selection: staged.sourceSelection),
                        selection: staged.sourceSelection,
                        placements: placements(staged.segmentation))
                    Divider()
                    importOptions
                }
                segmentation(staged.segmentation)
            }
        }
    }
}
