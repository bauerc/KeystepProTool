import Foundation
import KSPKit

// A Standard MIDI File counts its tracks in 16 bits, and parseSelection walks
// every number of a range, so this is both the real cap and a cheap one.
private let maxMidiTracks = 65535

public let midiTracksHelp = """
    read only these tracks of the source file, counting from 1 over every track of the file, \
    including ones that carry only tempo or a name: \(selectionHelp). Not usable with \
    --midi-track or --route
    """

/// The source tracks the two spellings name between them.
/// Empty is how `ImportOptions` spells "all of them".
public func resolveMidiTracks(_ single: Int?, _ listed: String?) throws -> Set<Int> {
    if single != nil && listed != nil {
        throw KSPError.value(
            "--midi-track and --midi-tracks contradict each other; --midi-track converts one "
                + "source track into the one pattern the target names, and --midi-tracks reads a "
                + "selection as a song")
    }
    if let single {
        // Range is ImportOptions' refusal to word, as it was before --midi-tracks existed.
        return [single]
    }
    return try parseSelection(listed, option: "--midi-tracks", limit: maxMidiTracks)
}
