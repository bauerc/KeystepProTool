import KSPKit

/// The `--drum-map` help text, shared by the three commands that take the option.
let drumMapHelp = """
    lane -> note mapping: chromatic:N, custom:a,b,c (24 notes) or none. The device's drum map is a \
    global setting and is not in the project file, so this defaults to \
    chromatic:\(DrumMap.defaultChromaticLow)
    """
