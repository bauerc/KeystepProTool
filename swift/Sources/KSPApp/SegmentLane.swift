import Foundation
import KSPKit
import KSPRun

/// Where a source track breaks into patterns once a hand has moved a boundary. Empty is the
/// automatic split, which is what leaves an untouched preview converting exactly as it did.
struct SegmentBoundaries: Equatable, Sendable {
    /// Ascending bars a pattern begins at, per source track. Bar 1 begins the first and is never
    /// listed, so a track here always carries at least one.
    private(set) var bars: [Int: [Int]] = [:]

    var isEdited: Bool { !bars.isEmpty }

    /// `--segment-bars` as the CLI spells it.
    var spec: String? {
        let pairs = bars.keys.sorted().flatMap { source in
            (bars[source] ?? []).map { "\(source):\($0)" }
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: ",")
    }

    /// A spec entry replaces the automatic cut for its track outright, so the first drag takes
    /// down every boundary the planner made, not only the one under the hand.
    mutating func seed(source: Int, bars automatic: [Int]) {
        guard bars[source] == nil, !automatic.isEmpty else { return }
        bars[source] = automatic
    }

    /// The bar comes from ``SegmentLane/bar(forHandle:atX:)``, which is where it is held between
    /// its neighbours; this only writes it down.
    mutating func move(source: Int, handle: Int, to bar: Int) {
        guard var moved = bars[source], moved.indices.contains(handle) else { return }
        moved[handle] = bar
        bars[source] = moved
    }

    mutating func reset() { bars = [:] }
}

/// One source track's run drawn as a strip as long as the track is: a region per pattern, each as
/// wide as it is long, and a handle on every boundary between them.
struct SegmentLane: Equatable, Identifiable {
    static let legend =
        "Drag a boundary to move where a pattern begins. A cut the device cannot play is refused, "
        + "never moved to one it can."

    struct Region: Equatable {
        let x: CGFloat
        let width: CGFloat
        let label: String
        let detail: String

        /// A one-bar region of a long run is a few points wide, where a label would only smear.
        var showsLabel: Bool { width >= AppLayout.laneLabelFloor }
    }

    struct Handle: Equatable, Identifiable {
        /// Its place in the track's own list of bars, as `--segment-bars` orders them.
        let index: Int
        let bar: Int
        let x: CGFloat

        var id: Int { index }
    }

    let sourceTrack: Int
    let name: String
    let barCount: Int
    let regions: [Region]
    let handles: [Handle]
    /// What a first drag here would move besides the boundary under the hand.
    let note: String?

    var id: Int { sourceTrack }

    /// The bars the boundaries sit at, which is what a first drag seeds ``SegmentBoundaries`` from.
    var bars: [Int] { handles.map(\.bar) }

    /// The lane label's tooltip.
    var detail: String {
        "\(name) — \(counted(barCount, "bar")), \(counted(regions.count, "pattern"))"
    }

    /// Every lane a plan has, in source order. Which source tracks get one is this type's to
    /// say rather than the view's.
    static func lanes(in summary: SegmentationSummary) -> [SegmentLane] {
        Set(summary.tracks.compactMap(\.sourceTrack)).sorted()
            .compactMap { SegmentLane(source: $0, summary: summary) }
    }

    /// `nil` where the plan placed nothing from this source track, and where the run's own cuts
    /// cannot be named in bars at all.
    init?(source: Int, summary: SegmentationSummary) {
        let parts = summary.tracks.filter { $0.sourceTrack == source && !$0.segments.isEmpty }
        // Channels of one source track become a device track each and can differ in length. The
        // longest is drawn, since the same bars cut every part and a boundary past a shorter one
        // is the planner's to refuse.
        guard let longest = parts.max(by: { $0.stepCount < $1.stepCount }) else { return nil }
        let stepsPerBar = summary.stepsPerBar
        let bars = longest.barCount(stepsPerBar: stepsPerBar)
        let cuts = longest.segments.dropFirst().map { $0.firstBar(stepsPerBar: stepsPerBar) }
        // A bar longer than the device's 64 steps puts two automatic cuts inside one of them,
        // which is a segmentation no `--segment-bars` can name. Such a run keeps the grid and
        // gets no lane, rather than a lane offering a boundary that could never be written.
        guard cuts.allSatisfy({ $0 > 1 }), zip(cuts, cuts.dropFirst()).allSatisfy({ $0 < $1 })
        else { return nil }

        let edges = [1] + Array(cuts) + [bars + 1]
        self.sourceTrack = source
        self.name = "Source \(source)"
        self.barCount = bars
        self.handles = cuts.enumerated().map {
            Handle(index: $0.offset, bar: $0.element, x: Self.x(ofBar: $0.element, in: bars))
        }
        self.note = Self.note(
            raggedCuts: longest.segments.dropFirst()
                .filter { ($0.firstStep - 1) % stepsPerBar != 0 }
                .map { $0.firstBar(stepsPerBar: stepsPerBar) })
        self.regions = zip(edges, edges.dropFirst()).enumerated().map { offset, edge in
            let x = Self.x(ofBar: edge.0, in: bars)
            return Region(
                x: x, width: Self.x(ofBar: edge.1, in: bars) - x,
                label: Self.label(from: edge.0, to: edge.1 - 1),
                detail: Self.detail(
                    // Which pattern a region fills reads unambiguously only where the source
                    // track became one device track.
                    pattern: parts.count == 1 ? longest.segments[offset].pattern : nil,
                    from: edge.0, to: edge.1 - 1, steps: longest.segments[offset].stepCount))
        }
    }

    /// The bar a handle dragged to `x` lands on, snapped and held between its neighbours. Past
    /// the step limit and past the free patterns stay the planner's to refuse.
    func bar(forHandle index: Int, atX x: CGFloat) -> Int {
        guard handles.indices.contains(index) else { return 0 }
        let width = AppLayout.laneWidth / CGFloat(max(1, barCount))
        let snapped = Int((x / width).rounded()) + 1
        let lowest = index == 0 ? 2 : handles[index - 1].bar + 1
        let highest = index == handles.count - 1 ? barCount : handles[index + 1].bar - 1
        return min(max(snapped, lowest), highest)
    }

    /// Where a handle dragged to `x` is drawn: on the bar it would land on, so a drag in flight
    /// shows the cut it is about to make rather than the pointer.
    func x(forHandle index: Int, atX x: CGFloat) -> CGFloat {
        self.x(ofBar: bar(forHandle: index, atX: x))
    }

    /// The leading edge of a bar, 1-based, in the lane's own coordinates, which is where a
    /// boundary beginning at it is drawn.
    func x(ofBar bar: Int) -> CGFloat { Self.x(ofBar: bar, in: barCount) }

    private static func x(ofBar bar: Int, in barCount: Int) -> CGFloat {
        AppLayout.laneWidth * CGFloat(bar - 1) / CGFloat(max(1, barCount))
    }

    /// A segmentation can only name bars, so a cut the automatic split put inside one has to move
    /// to its start the moment any boundary here is dragged. Said before it happens, not after.
    private static func note(raggedCuts bars: [Int]) -> String? {
        guard !bars.isEmpty else { return nil }
        let named = bars.map(String.init).joined(separator: ", ")
        return "Its automatic cut falls inside bar \(named) rather than on it. Moving any "
            + "boundary here pulls that cut to the bar's start, since a segmentation names bars."
    }

    private static func label(from first: Int, to last: Int) -> String {
        first == last ? "bar \(first)" : "bars \(first)-\(last)"
    }

    private static func detail(pattern: Int?, from: Int, to: Int, steps: Int) -> String {
        guard let pattern else { return label(from: from, to: to) }
        return "Pattern \(pattern) — \(label(from: from, to: to)), \(counted(steps, "step"))"
    }
}
