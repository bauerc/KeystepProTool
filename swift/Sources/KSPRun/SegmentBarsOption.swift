import Foundation
import KSPKit
import KSPMIDI

/// The largest number a pair may spell; an oversized numeral is refused by the grammar.
private let maxNumber = 2_147_483_647

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
        let source = item.prefix { $0 != ":" }
        guard source.count != item.count else {
            throw KSPError.value("--segment-bars: '\(item)' is not a source:bar pair")
        }
        let bar = item.dropFirst(source.count + 1)
        guard !bar.contains(":") else {
            throw KSPError.value("--segment-bars: '\(item)' is not a source:bar pair")
        }
        let track = try number(source, item: item)
        let boundary = try number(bar, item: item)
        if let index = gathered.firstIndex(where: { $0.source == track }) {
            gathered[index].bars.append(boundary)
        } else {
            gathered.append((source: track, bars: [boundary]))
        }
    }
    return gathered.map { TrackSegments(source: $0.source, bars: $0.bars) }
}

private func number(_ text: some StringProtocol, item: String) throws -> Int {
    // Spelled out rather than left to `Int`, which differs from Python's `int` on what it takes.
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var digits = Substring(body)
    if digits.first == "+" || digits.first == "-" { digits = digits.dropFirst() }
    guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
        throw KSPError.value("--segment-bars: '\(item)' is not a source:bar pair")
    }
    // `magnitude`, not `abs`: `abs(Int.min)` traps, so a pasted `Int.min` would crash the CLI.
    guard let value = Int(body), value.magnitude <= UInt(maxNumber) else {
        throw KSPError.value("--segment-bars: '\(item)' names a number too large to be one")
    }
    return value
}
