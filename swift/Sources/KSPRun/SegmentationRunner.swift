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
        /// A boundary the planner refused, as against a file it could not read: a caller offering
        /// boundaries can put its own back where they were, where it can do nothing about a file.
        public let isRefusal: Bool

        public init(
            summary: SegmentationSummary? = nil, message: String? = nil, isRefusal: Bool = false
        ) {
            self.summary = summary
            self.message = message
            self.isRefusal = isRefusal
        }
    }

    public static func run(_ options: ConvertRunner.Options) -> Outcome {
        // The single-target path quantises to the length of the template pattern it is aimed at,
        // so a preview that reads no template has nothing to work from.
        if options.midiTrack != nil {
            return Outcome(message: "a single-target import has no segmentation to preview")
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
                summary: SegmentationSummary(
                    song: song, plan: plan,
                    stepsPerBar: song.stepsPerBar(importOptions.stepsPerBeat)))
        } catch KSPError.segment(let message) {
            return Outcome(message: message, isRefusal: true)
        } catch let error as ConvertRunner.ReadFailure {
            return Outcome(message: error.message)
        } catch {
            return Outcome(message: "\(error)")
        }
    }
}
