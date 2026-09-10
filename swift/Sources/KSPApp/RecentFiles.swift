import AppKit

/// Open Recent. The list is `NSDocumentController`'s, which is the same one the Dock icon's own
/// menu shows, so an app without an `NSDocument` still keeps both in step.
struct RecentFiles {
    var urls: @MainActor () -> [URL]
    var note: @MainActor (URL) -> Void
    var clear: @MainActor () -> Void

    @MainActor
    static var documentController: RecentFiles {
        RecentFiles(
            urls: { NSDocumentController.shared.recentDocumentURLs },
            note: { NSDocumentController.shared.noteNewRecentDocumentURL($0) },
            clear: { NSDocumentController.shared.clearRecentDocuments(nil) })
    }
}
