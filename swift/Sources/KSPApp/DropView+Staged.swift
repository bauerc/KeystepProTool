import AppKit
import KSPKit
import KSPMIDI
import KSPRun
import SwiftUI

extension DropView {
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

    var prompt: some View {
        Text("Drop a MIDI file or a KeyStep Pro project")
            .font(.title3)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: AppLayout.cardRadius).fill(palette.ground))
    }

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
