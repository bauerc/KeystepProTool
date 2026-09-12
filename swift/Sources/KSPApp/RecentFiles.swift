import AppKit

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
