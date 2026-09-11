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
    /// The whole path, for a reader who does not get the folder the bar truncates away.
    let spoken: String

    init(_ plan: Conversion.Plan) {
        self.init(
            plan.target, intoFolder: plan.intoFolder,
            verb: plan.intoFolder ? "Writes into" : "Writes to")
    }

    /// Where a finished run's files are, which is always a folder: the result above it has
    /// already named the files, and a split run or a read can write several.
    init?(_ outcome: Outcome) {
        guard !outcome.failed, let directory = outcome.directory else { return nil }
        self.init(directory, intoFolder: true, verb: "Written into")
    }

    private init(_ target: URL, intoFolder: Bool, verb: String) {
        let directory = target.deletingLastPathComponent()
        self.folder = (directory.path as NSString).abbreviatingWithTildeInPath
        self.name = target.lastPathComponent
        self.path = target.path
        self.intoFolder = intoFolder
        self.spoken = "\(verb) \(target.path)"
    }
}
