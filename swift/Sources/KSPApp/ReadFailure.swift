import Foundation
import KSPRun
import os

private let log = Logger(subsystem: "com.github.bauerc.keysteppro-plus", category: "read")

/// A refused file, split into the registers the window needs: a sentence for whoever dropped it,
/// the path beneath that, and a reason short enough to sit beside Convert.
struct ReadFailure: Equatable {
    let headline: String
    let path: String

    /// The action bar's line while this stands. It says the same thing as ``headline`` because
    /// Convert is where the promise was made, and it is one line wide.
    var blockReason: String { "This file can't be read, so there is nothing to convert." }

    /// The type's own words never reach the window, so they are logged here: without this line a
    /// header mismatch leaves no trace at all.
    init(_ failure: SummaryRunner.Failure, kind: Job.Kind) {
        log.error("\(failure.message, privacy: .public)")
        let name = failure.path.lastPathComponent
        self.path = failure.path.path
        self.headline =
            switch failure.reason {
            case .unopenable:
                "\(name) could not be opened. It may have been moved or renamed since it was "
                    + "dropped."
            case .unrecognised where kind == .toProject:
                "\(name) isn't a MIDI file — its header doesn't match. Try re-exporting it from "
                    + "your DAW as a Standard MIDI File."
            case .unrecognised:
                "\(name) isn't a KeyStep Pro project — its contents don't match the format. Try "
                    + "exporting it again from MIDI Control Center."
            case .refused:
                "\(name) could not be read: \(failure.detail)"
            }
    }
}
