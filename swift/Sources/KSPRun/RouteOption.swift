import Foundation
import KSPKit
import KSPMIDI

/// The largest track number a pair may spell; an oversized numeral is refused by the grammar.
private let maxTrack = 2_147_483_647

public let routeHelp = """
    send named source tracks to named device tracks: source:device pairs, comma-separated \
    (e.g. 3:1,1:2), both counting from 1. Tracks no pair names fill whatever is left, in source \
    order as usual. Only KeyStep Pro track 1 carries a drum set, so a --drum-track may only be \
    routed there and nothing else may be routed onto it. Not usable with --midi-track \
    or --midi-tracks
    """

/// `nil` gives the empty array, which is how `ImportOptions` already spells "assign as before".
public func parseRoutes(_ text: String?) throws -> [TrackRoute] {
    guard let text else { return [] }
    var routes: [TrackRoute] = []
    for field in text.split(separator: ",", omittingEmptySubsequences: false) {
        let item = field.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = item.prefix { $0 != ":" }
        guard source.count != item.count else {
            throw KSPError.value("--route: '\(item)' is not a source:device pair")
        }
        let device = item.dropFirst(source.count + 1)
        guard !device.contains(":") else {
            throw KSPError.value("--route: '\(item)' is not a source:device pair")
        }
        routes.append(
            TrackRoute(
                source: try number(source, item: item), device: try number(device, item: item)))
    }
    return routes
}

private func number(_ text: some StringProtocol, item: String) throws -> Int {
    // Spelled out rather than left to `Int`, which differs from Python's `int` on what it takes.
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var digits = Substring(body)
    if digits.first == "+" || digits.first == "-" { digits = digits.dropFirst() }
    guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
        throw KSPError.value("--route: '\(item)' is not a source:device pair")
    }
    // `magnitude`, not `abs`: `abs(Int.min)` traps, so a pasted `Int.min` would crash the CLI.
    guard let value = Int(body), value.magnitude <= UInt(maxTrack) else {
        throw KSPError.value("--route: '\(item)' names a track number too large to be one")
    }
    return value
}
