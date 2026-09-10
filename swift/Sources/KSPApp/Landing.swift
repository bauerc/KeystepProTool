import Foundation

/// Where a conversion lands, as the action bar says it: the folder quietly, the name in ink.
struct Landing: Equatable {
    /// What is said where there is no landing at all, because the file was refused.
    static let nowhere = "No destination, because there is nothing to write."

    let folder: String
    let name: String
    let path: String
    /// A split run fills a folder, so ``name`` is that folder rather than a file in it.
    let intoFolder: Bool

    init(_ plan: Conversion.Plan) {
        let directory = plan.target.deletingLastPathComponent()
        self.folder = (directory.path as NSString).abbreviatingWithTildeInPath
        self.name = plan.target.lastPathComponent
        self.path = plan.target.path
        self.intoFolder = plan.intoFolder
    }

    /// The whole path, for a reader who does not get the folder the bar truncates away.
    var spoken: String { "\(intoFolder ? "Writes into" : "Writes to") \(path)" }
}
