import Foundation

enum Chase {
    /// How long one column stays lit, and so the 1.12s a crossing of the sixteen takes.
    static let step: TimeInterval = 0.07

    static let holdOff: TimeInterval = 0.35

    static var sweep: TimeInterval { step * Double(AppLayout.columnCount) }

    static func column(after elapsed: TimeInterval) -> Int? {
        guard elapsed >= holdOff else { return nil }
        let position = (elapsed - holdOff).truncatingRemainder(dividingBy: sweep)
        return min(AppLayout.columnCount - 1, Int(position / step))
    }
}
