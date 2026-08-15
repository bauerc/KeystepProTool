import AppKit
import SwiftUI

/// The drag-and-drop face of the converter (M13.2).
///
/// It owns no format logic at all: a drop resolves to a ``Job``, the job calls the same
/// `ConvertRunner`/`ExportRunner` that `ksp-swift-cli` calls, and the window renders the
/// `RunResult` the runner hands back. That is what keeps the parity scripts meaningful -- a bug
/// fixed for the CLI is fixed here by construction, because there is only one implementation.
@main
struct KSPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("KeyStep Pro Tool") {
            DropView(model: .shared)
        }
        .windowResizability(.contentSize)
    }
}

/// Drops onto the Dock icon, which `.dropDestination` inside the window never sees.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let first = urls.first else { return }
        MainActor.assumeIsolated { AppModel.shared.accept(first) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
