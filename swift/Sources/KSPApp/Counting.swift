import Foundation

/// Pluralised by the count, for the several views that say "3 notes" or "1 bar".
func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}

/// A row head's pattern number, two digits as the device's four displays show it, or `--` where
/// the track is on no pattern at all. Shared so both grids read the same way round.
func patternReadout(_ pattern: Int?) -> String {
    pattern.map { String(format: "%02d", $0) } ?? "--"
}
