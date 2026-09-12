import Foundation
import KSPKit

// A Standard MIDI File counts its tracks in 16 bits.
private let maxMidiTracks = 65535

public let midiTracksHelp = """
    read only these tracks of the source file, counting from 1 over every track of the file, \
    including ones that carry only tempo or a name: \(selectionHelp). Not usable with \
    --midi-track
    """

public func resolveMidiTracks(_ single: Int?, _ listed: String?) throws -> Set<Int> {
    if single != nil && listed != nil {
        throw KSPError.value(
            "--midi-track and --midi-tracks contradict each other; --midi-track converts one "
                + "source track into the one pattern the target names, and --midi-tracks reads a "
                + "selection as a song")
    }
    if let single {
        return [single]
    }
    return try parseSelection(listed, option: "--midi-tracks", limit: maxMidiTracks)
}
