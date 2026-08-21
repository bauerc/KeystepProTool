import AppKit
import SwiftUI

@main
struct KSPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Key Step Pro Plus") {
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
