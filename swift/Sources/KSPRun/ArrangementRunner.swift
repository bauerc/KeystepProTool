import Foundation
import KSPKit
import KSPMIDI

public enum ArrangementRunner {
    public struct Outcome: Sendable {
        public let summary: ArrangementSummary?
        public let message: String?

        public init(summary: ArrangementSummary? = nil, message: String? = nil) {
            self.summary = summary
            self.message = message
        }
    }

    public static func run(_ options: ExportRunner.Options) -> Outcome {
        if options.split {
            return Outcome(
                message: "a split export writes one file per pattern, so there is no "
                    + "shared timeline to show")
        }

        do {
            guard
                let drumMap = try resolveDrumMap(
                    options.drumMapSpec, configPath: options.configPath)
            else {
                return Outcome(
                    message: "--drum-map none names no note for a drum lane, so there "
                        + "is nothing to lay out")
            }
            let exportOptions = try ExportRunner.exportOptions(options, drumMap: drumMap)
            let project = try Reader.load(contentsOf: options.path)
                .select(tracks: options.tracks, patterns: options.patterns)
                .select(cells: options.cells)
            let renderings = try MIDIExport.renderProject(project, options: exportOptions)
            let arrangement = try MIDIExport.arrange(
                renderings, repeat: exportOptions.repeatCount)
            return Outcome(
                summary: ArrangementSummary(
                    renderings: renderings, arrangement: arrangement,
                    ticksPerBeat: options.ticksPerBeat))
        } catch let error as KSPError {
            return Outcome(message: "\(options.path.relativePath): \(error)")
        } catch {
            return Outcome(message: "\(error.localizedDescription)")
        }
    }
}
