import AppKit
import KSPKit
import KSPMIDI
import KSPRun
import SwiftUI

struct DropView: View {
    @Bindable var model: AppModel
    @State var targeted = false
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
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
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .dropDestination(for: URL.self) { urls, _ in
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

    private var scheme: ColorScheme { model.appearance.colorScheme ?? systemScheme }
    var palette: Palette { Palette.resolved(for: scheme) }

    private var windowTitle: String {
        switch model.phase {
        case .idle: return "Key Step Pro Plus"
        case .staged(let staged): return model.plan(for: staged.job).source.lastPathComponent
        case .working(let filename): return filename
        case .reading(let slot): return "Project \(slot)"
        case .done(let outcome): return outcome.document
        }
    }

    private var windowSubtitle: String {
        switch model.phase {
        case .idle, .working: return ""
        case .staged(let staged): return staged.job.direction
        case .reading: return DeviceRead.direction
        case .done(let outcome): return outcome.direction
        }
    }

    @ViewBuilder
    var content: some View {
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
}
