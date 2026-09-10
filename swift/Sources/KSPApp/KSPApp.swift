import AppKit
import SwiftUI

@main
struct KSPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// A `Window` rather than a `WindowGroup`: one window is one conversion, and a second file
    /// replaces what is staged instead of opening a second window onto the same model.
    var body: some Scene {
        Window("Key Step Pro Plus", id: "conversion") {
            DropView(model: .shared)
        }
        .defaultSize(
            width: AppLayout.defaultWindowWidth, height: AppLayout.defaultWindowHeight
        )
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
    }
}

/// Drops onto the Dock icon, which `.dropDestination` inside the window never sees, and every
/// file Launch Services routes here.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let first = urls.first else { return }
        MainActor.assumeIsolated {
            AppModel.shared.accept(first)
            surface(application)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The one window holds the whole app, so a file opened while it is behind another app or
    /// miniaturised would otherwise land unseen.
    @MainActor
    private func surface(_ application: NSApplication) {
        application.activate()
        guard let window = application.windows.first(where: \.canBecomeMain) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}
