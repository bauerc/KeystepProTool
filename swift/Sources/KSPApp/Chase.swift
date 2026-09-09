import Foundation

/// The white playhead that crosses the pattern map while a conversion runs, after §4.2.9's "the
/// currently playing step, which is lit up in white". The one thing in the app that moves.
enum Chase {
    /// How long one column stays lit, and so the 1.12s a crossing of the sixteen takes.
    static let step: TimeInterval = 0.07

    /// The floor, held before the first column rather than open after the last: holding a chase
    /// open would gate the result on the animation, and a failure the user needs to see with it.
    /// A conversion that finishes inside this leaves the map exactly as it was, so nothing flashed.
    static let holdOff: TimeInterval = 0.35

    /// One crossing of the map, which the playhead starts again from the left.
    static var sweep: TimeInterval { step * Double(AppLayout.columnCount) }

    /// The lit column, 0-based, or `nil` while the chase is still held off. Taken modulo the sweep
    /// before it is a column, so a conversion of any length lights one of the sixteen.
    static func column(after elapsed: TimeInterval) -> Int? {
        guard elapsed >= holdOff else { return nil }
        let position = (elapsed - holdOff).truncatingRemainder(dividingBy: sweep)
        return min(AppLayout.columnCount - 1, Int(position / step))
    }
}
