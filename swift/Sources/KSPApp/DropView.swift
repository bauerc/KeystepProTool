import AppKit
import KSPKit
import SwiftUI

/// The window's state. The one place in the app that is mutable, and it is main-actor confined --
/// everything below `KSPApp` is a value type the runners already declare `Sendable`.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Phase {
        case idle
        case working(String)
        case done(Outcome)
    }

    var phase: Phase = .idle
    var name: String = ""
    var verbose = false

    func accept(_ url: URL) {
        guard let job = Conversion.job(for: url) else {
            phase = .done(
                Outcome(
                    written: nil,
                    headline: "\(url.lastPathComponent) is not a MIDI file or a KeyStep Pro "
                        + "project.", report: Report(), note: nil))
            return
        }
        let stem = Naming.stem(of: url)
        name = stem
        phase = .working(url.lastPathComponent)

        let destination =
            switch job {
            case .toProject: Destinations.forProjects()
            case .toMIDI: Destinations.beside(url)
            }

        Task {
            let outcome = await Conversion.run(job, named: stem, into: destination)
            if let written = outcome.written {
                self.name = written.deletingPathExtension().lastPathComponent
                NSWorkspace.shared.activateFileViewerSelecting([written])
            }
            self.phase = .done(outcome)
        }
    }

    /// Rename what was just written, in place. MCC's Project Browser lists the filename, so this
    /// is how a project gets the name it will carry on the device.
    func renameResult() {
        guard case .done(var outcome) = phase, let written = outcome.written else { return }
        do {
            let moved = try Naming.rename(written, toStem: name)
            outcome.written = moved
            outcome.note = nil
            name = moved.deletingPathExtension().lastPathComponent
            phase = .done(outcome)
            NSWorkspace.shared.activateFileViewerSelecting([moved])
        } catch {
            outcome.note = "Could not rename: \(error.localizedDescription)"
            phase = .done(outcome)
        }
    }

    func reset() {
        phase = .idle
        name = ""
    }
}

struct DropView: View {
    @Bindable var model: AppModel
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 16) {
            content
        }
        .padding(24)
        .frame(width: 460, height: 300)
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

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            idle
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

            if !outcome.failed {
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

            if !outcome.report.isEmpty {
                DisclosureGroup("\(outcome.report.count) note(s)") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(outcome.findings(verbose: model.verbose), id: \.self) { finding in
                            Text(finding).font(.caption).textSelection(.enabled)
                        }
                        if outcome.hasDetail {
                            Toggle("Show each one", isOn: $model.verbose)
                                .font(.caption).toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer()
            Button("Convert another") { model.reset() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
