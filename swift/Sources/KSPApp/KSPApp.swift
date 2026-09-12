import AppKit
import SwiftUI

@main
struct KSPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Key Step Pro Plus", id: "conversion") {
            DropView(model: .shared)
        }
        .defaultSize(
            width: AppLayout.defaultWindowWidth, height: AppLayout.defaultWindowHeight
        )
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands { FileCommands(model: .shared) }

        SwiftUI.Settings {
            SettingsWindow(model: .shared)
        }
    }
}

struct FileCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.open() }
                .keyboardShortcut("o")
                .disabled(!model.canAccept)

            Menu("Open Recent") {
                ForEach(model.recentFiles, id: \.self) { url in
                    Button(url.lastPathComponent) { model.accept(url) }
                }
                Divider()
                Button("Clear Menu") { model.clearRecentFiles() }
                    .disabled(model.recentFiles.isEmpty)
            }
            .disabled(!model.canAccept)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let first = urls.first else { return }
        MainActor.assumeIsolated {
            AppModel.shared.accept(first)
            surface(application)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    private func surface(_ application: NSApplication) {
        application.activate()
        guard let window = application.windows.first(where: \.canBecomeMain) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}
