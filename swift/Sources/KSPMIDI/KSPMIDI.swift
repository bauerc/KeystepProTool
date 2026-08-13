import SwiftMIDIFile

/// Namespace for the Standard MIDI File layer, the port of `midi_export.py` and `midi_import.py`.
///
/// Empty until M12. This is the only target that imports `SwiftMIDIFile`, mirroring the Python's
/// rule that only `build_midi_file` and `read_clip` touch `mido`. Keeping it separate from
/// ``KSPKit`` is also what makes the format core portable: `swift-midi-file` is Apple-only.
public enum KSPMIDI {
    /// Matches `ksp.midi_export.DEFAULT_TICKS_PER_BEAT`; divisible by 24, so every step size and
    /// its triplet lands on an integer tick.
    public static let defaultTicksPerQuarterNote: UInt16 = 480
}
