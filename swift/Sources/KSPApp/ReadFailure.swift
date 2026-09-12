import Foundation
import KSPRun
import os

private let log = Logger(subsystem: "com.github.bauerc.keysteppro-plus", category: "read")

struct ReadFailure: Equatable {
    let headline: String
    let path: String

    var blockReason: String { "This file can't be read, so there is nothing to convert." }

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
