import Foundation
import KSPKit
import KSPMIDI

/// A dry run of the import planner: it reads, plans, and writes nothing. It loads no template --
/// `planSong` needs none -- which is what makes it cheap enough to run again on every tick.
public enum SegmentationRunner {
    public struct Outcome: Sendable {
        public let summary: SegmentationSummary?
        /// Why there is no summary, in the words the runner would have failed with.
        public let message: String?
        /// The planner's own findings, so what an import would lose is said before it runs rather
        /// than after.
        public let diagnostics: Report

        public init(
            summary: SegmentationSummary? = nil, message: String? = nil,
            diagnostics: Report = Report()
        ) {
            self.summary = summary
            self.message = message
            self.diagnostics = diagnostics
        }
    }

    public static func run(_ options: ConvertRunner.Options) -> Outcome {
        // The single-target path quantises to the length of the template pattern it is aimed at,
        // so a preview that reads no template has nothing to work from.
        if options.midiTrack != nil {
            return Outcome(message: "a single-target import has nothing to preview")
        }

        do {
            let importOptions = try ConvertRunner.importOptions(options)
            let sources = try ConvertRunner.readSources(options)
            try MIDIImport.checkSelections(sources, importOptions)
            let song = try MIDIImport.readSongs(sources, options: importOptions)
            let plan = try MIDIImport.planSong(
                song, options: importOptions, firstPattern: options.pattern,
                firstTrack: options.track)
            return Outcome(
                summary: SegmentationSummary(song: song, plan: plan),
                diagnostics: plan.diagnostics)
        } catch let error as ConvertRunner.ReadFailure {
            return Outcome(message: error.message)
        } catch {
            return Outcome(message: "\(error)")
        }
    }
}
