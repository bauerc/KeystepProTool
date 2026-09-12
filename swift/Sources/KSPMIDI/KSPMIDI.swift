public enum KSPMIDI {
    /// MIDI's sixteen channels, numbered from 1 as the CLI and the app count them. The import and
    /// export cores count from 0, so their own checks read `0...15` rather than this.
    public static let channels = 1...16
}
