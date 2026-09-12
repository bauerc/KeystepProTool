import AppKit
import KSPKit
import KSPMIDI
import KSPRun
import SwiftUI

/// What a finished conversion reports.
extension DropView {
    @ViewBuilder
    func dryRunPreview(_ preview: Outcome) -> some View {
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

    /// What the run made, leading the window a size above everything it heads. The glyph carries
    /// the status and the colour only agrees: Track 2 is orange and Track 4 is red.
    private func resultHeader(_ outcome: Outcome) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: outcome.failed ? StatusMark.error : StatusMark.success)
                .font(TypeScale.resultMark)
                .foregroundStyle(outcome.failed ? palette.error : palette.success)
                .accessibilityLabel(outcome.failed ? "Failed" : "Done")
            VStack(alignment: .leading, spacing: 4) {
                Text(outcome.resultLine)
                    .font(TypeScale.header).lineLimit(1).truncationMode(.middle)
                headline(outcome, font: TypeScale.label, figures: TypeScale.headlineValue)
                    .foregroundStyle(outcome.failed ? palette.ink : palette.mutedInk)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    func done(_ outcome: Outcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    resultHeader(outcome)
                    if outcome.written.count > 1 { writtenFiles(outcome.written) }

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
    func nameHelp(_ plan: Conversion.Plan) -> String {
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
    func findingList(_ findings: [Finding], count: Int) -> some View {
        if count > 0 {
            DisclosureGroup("\(count) finding(s)") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(findings) { finding in
                        HStack(alignment: .firstTextBaseline, spacing: AppLayout.labelGap) {
                            Image(systemName: style(finding.severity).symbol)
                                .font(.caption2)
                                .foregroundStyle(style(finding.severity).colour)
                                .frame(width: AppLayout.findingGlyphWidth, alignment: .leading)
                                .accessibilityLabel(
                                    finding.severity == .error ? "Error" : "Warning")
                            figured(finding.text, font: .caption)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
