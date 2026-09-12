import Foundation
import KSPKit
import KSPMIDI

public enum SegmentationRunner {
    public struct Outcome: Sendable {
        public let summary: SegmentationSummary?
        public let message: String?
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
        // The single-target path quantises to its template pattern's length, which is unread here.
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
