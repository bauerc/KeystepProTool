import SwiftMIDIFile

/// Namespace for the Standard MIDI File layer, the only target that imports `SwiftMIDIFile`.
public enum KSPMIDI {
    /// Divisible by 24, so every step size and its triplet lands on an integer tick.
    public static let defaultTicksPerQuarterNote: UInt16 = 480
}
