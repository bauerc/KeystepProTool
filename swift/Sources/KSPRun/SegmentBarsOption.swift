import Foundation
import KSPKit
import KSPMIDI

public let segmentBarsHelp = """
    break named source tracks into patterns at named bars: source:bar pairs, comma-separated \
    (e.g. 2:5,2:9,3:3), both counting from 1. Bar 1 begins the first pattern, so it is never a \
    boundary, and a track's bars must ascend. Tracks no pair names are still cut at the device's \
    64 steps as before. Not usable with --midi-track
    """

/// The segmentation the spec names, gathered one entry per source track.
/// Empty is how `ImportOptions` spells "the automatic split, as before".
public func resolveSegments(_ single: Int?, _ spec: String?) throws -> [TrackSegments] {
    if single != nil && spec != nil {
        throw KSPError.value(
            "--midi-track and --segment-bars contradict each other; --midi-track converts one "
                + "source track into the one pattern the target names, and a segmentation cuts a "
                + "track across several")
    }
    guard let spec else { return [] }
    // An array rather than a Dictionary: the entries keep the order the tracks were first
    // mentioned in, and Swift's Dictionary iteration is nondeterministic.
    var gathered: [(source: Int, bars: [Int])] = []
    for field in spec.split(separator: ",", omittingEmptySubsequences: false) {
        let item = field.trimmingCharacters(in: .whitespacesAndNewlines)
        let malformed = "--segment-bars: '\(item)' is not a source:bar pair"
        let oversized = "--segment-bars: '\(item)' names a number too large to be one"
        let source = item.prefix { $0 != ":" }
        guard source.count != item.count else { throw KSPError.value(malformed) }
        let bar = item.dropFirst(source.count + 1)
        guard !bar.contains(":") else { throw KSPError.value(malformed) }
        let track = try pairInt(source, malformed: malformed, oversized: oversized)
        let boundary = try pairInt(bar, malformed: malformed, oversized: oversized)
        if let index = gathered.firstIndex(where: { $0.source == track }) {
            gathered[index].bars.append(boundary)
        } else {
            gathered.append((source: track, bars: [boundary]))
        }
    }
    return gathered.map { TrackSegments(source: $0.source, bars: $0.bars) }
}
