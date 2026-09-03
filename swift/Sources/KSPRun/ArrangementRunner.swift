import Foundation
import KSPKit
import KSPMIDI

/// A dry run of the export's own arithmetic: it reads, renders, arranges, and writes nothing. It
/// runs the two calls `exportProject` runs, so the timeline it shows is the one the `.mid` gets.
public enum ArrangementRunner {
    /// No `diagnostics` beside the summary, as `SegmentationRunner.Outcome` carries: the findings
    /// are on ``ArrangementSummary`` itself, where every other summary in this module keeps them.
    public struct Outcome: Sendable {
        public let summary: ArrangementSummary?
        /// Why there is no summary, in the words the runner would have failed with.
        public let message: String?

        public init(summary: ArrangementSummary? = nil, message: String? = nil) {
            self.summary = summary
            self.message = message
        }
    }

    public static func run(_ options: ExportRunner.Options) -> Outcome {
        // A split run writes one file per Pattern, each starting at tick 0, so the shared timeline
        // the lanes are of is not a thing that run produces.
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
            // Narrowed as `ExportRunner.plan` narrows it, so an unticked slot leaves the preview
            // as it leaves the file.
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
