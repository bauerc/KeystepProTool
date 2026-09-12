import Foundation

struct Landing: Equatable {
    static let nowhere = "No destination, because there is nothing to write."

    let folder: String
    let name: String
    let path: String
    let intoFolder: Bool
    let spoken: String

    init(_ plan: Conversion.Plan) {
        self.init(
            plan.target, intoFolder: plan.intoFolder,
            verb: plan.intoFolder ? "Writes into" : "Writes to")
    }

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
