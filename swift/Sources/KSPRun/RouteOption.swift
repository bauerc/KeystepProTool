import Foundation
import KSPKit
import KSPMIDI

public let routeHelp = """
    send named source tracks to named device tracks: source:device pairs, comma-separated \
    (e.g. 3:1,1:2), both counting from 1. Tracks no pair names fill whatever is left, in source \
    order as usual. Only KeyStep Pro track 1 carries a drum set, so a --drum-track may only be \
    routed there and nothing else may be routed onto it. A route may only name a source track \
    --midi-tracks reads. Not usable with --midi-track
    """

/// The routes the text names, in the order it names them.
/// Empty is how `ImportOptions` already spells "assign as before".
public func resolveRoutes(_ single: Int?, _ text: String?) throws -> [TrackRoute] {
    if single != nil && text != nil {
        throw KSPError.value(
            "--midi-track and --route contradict each other; --midi-track converts one source "
                + "track into the one pattern the target names, and a route says which device "
                + "track a source track fills")
    }
    guard let text else { return [] }
    var routes: [TrackRoute] = []
    for field in text.split(separator: ",", omittingEmptySubsequences: false) {
        let item = field.trimmingCharacters(in: .whitespacesAndNewlines)
        let malformed = "--route: '\(item)' is not a source:device pair"
        let oversized = "--route: '\(item)' names a track number too large to be one"
        let source = item.prefix { $0 != ":" }
        guard source.count != item.count else { throw KSPError.value(malformed) }
        let device = item.dropFirst(source.count + 1)
        guard !device.contains(":") else { throw KSPError.value(malformed) }
        routes.append(
            TrackRoute(
                source: try pairInt(source, malformed: malformed, oversized: oversized),
                device: try pairInt(device, malformed: malformed, oversized: oversized)))
    }
    return routes
}
