/// The addresses `BulkPlan` lists, in as few requests as the device allows (spec 7.8).
public enum BulkFast {
    /// Marks an empty note-pool entry. Also a legal pitch and velocity, which is why
    /// only paramId 50 (or 54) may be read as existence (spec 3).
    public static let empty = 127

    /// The melodic existence array, and the per-note parameters it gates. Entry n of
    /// each is the same note ordinal, so an all-empty chunk of 50 settles all of them.
    public static let melodicGate = 50
    public static let melodicGated: Set<Int> = [109, 110, 111, 112, 113]

    // The drum pair (54 gating 117-121) is deliberately absent: the drum array is a
    // pool with holes, so a dead entry keeps whatever was there and cannot be derived.

    /// Requests this plan expands to, against the 8,951 MCC issues.
    public static let requestCount = 2044

    /// What one pattern of one track costs: 75 pattern reads plus the index-less scalars.
    public static let patternRequestCount = 115

    /// Every address the plan covers, coalesced into the fewest requests.
    /// MCC's order, but with the existence array ahead of the parameters it gates.
    public static func iterRequests(maxCount: Int = Sysex.maxReadCount) throws -> [ReadRequest] {
        guard maxCount > 0 else {
            throw KSPError.value("maxCount \(maxCount), expected 1 or more")
        }
        var requests: [ReadRequest] = []
        for group in BulkPlan.plan {
            let expanded = (group.low...group.high).flatMap { expand($0, group.leaves) }
            requests += try coalesce(expanded, maxCount: maxCount)
        }
        return requests
    }

    /// The requests covering one pattern of one track, in `iterRequests`' order.
    /// The index-less scalars come too: tempo carries no pattern index.
    public static func iterPatternRequests(item: Int, pattern: Int) throws -> [ReadRequest] {
        try iterRequests().filter {
            $0.count == nil || ($0.item == item && covers($0, pattern))
        }
    }

    /// Whether a request fills any key belonging to `pattern`. Not simply
    /// `indices[0] == pattern`: a coalesced per-pattern scalar is one range at index 1.
    private static func covers(_ request: ReadRequest, _ pattern: Int) -> Bool {
        guard let count = request.count, let first = request.indices.first else { return false }
        guard request.indices.count == 1 else { return first == pattern }
        return first <= pattern && pattern < first + count
    }

    /// One group index of the plan, in the plan's own order.
    private static func expand(_ index: Int, _ leaves: [BulkPlan.Leaf]) -> [ReadRequest] {
        var requests: [ReadRequest] = []
        for leaf in leaves {
            guard let count = leaf.count else {
                requests += leaf.params.map { ReadRequest(item: leaf.item, param: $0) }
                continue
            }
            let resolved = leaf.dims.map { dim in dim.map { $0 == BulkPlan.idx ? index : $0 } }
            for param in leaf.params {
                requests += product(resolved).map {
                    ReadRequest(item: leaf.item, param: param, indices: $0, count: count)
                }
            }
        }
        return requests
    }

    /// Cartesian product with the last dimension varying fastest, as `itertools.product`.
    private static func product(_ dims: [[Int]]) -> [[Int]] {
        var rows: [[Int]] = [[]]
        for dim in dims {
            rows = rows.flatMap { row in dim.map { row + [$0] } }
        }
        return rows
    }

    /// One run: `(item, param, fixed indices)`, the walking index left out.
    private struct RunKey: Hashable {
        let item: Int
        let param: Int
        let head: [Int]
    }

    /// Join each run over the walking index into requests of up to `maxCount`.
    /// Only the last index walks; the others hold a run together.
    private static func coalesce(_ requests: [ReadRequest], maxCount: Int) throws -> [ReadRequest] {
        var runs: [RunKey: Int] = [:]
        var order: [[ReadRequest]] = []
        for request in requests {
            guard request.count != nil else {
                order.append([request])
                continue
            }
            let key = RunKey(
                item: request.item,
                param: request.param,
                head: Array(request.indices.dropLast())
            )
            if let position = runs[key] {
                order[position].append(request)
            } else {
                runs[key] = order.count
                order.append([request])
            }
        }
        return try gateFirst(order).flatMap { try join($0, maxCount: maxCount) }
    }

    /// The existence array ahead of the notes it gates, order otherwise kept.
    private static func gateFirst(_ order: [[ReadRequest]]) -> [[ReadRequest]] {
        order.filter { $0[0].param == melodicGate } + order.filter { $0[0].param != melodicGate }
    }

    private static func join(_ run: [ReadRequest], maxCount: Int) throws -> [ReadRequest] {
        let first = run[0]
        guard first.count != nil else { return [first] }

        // By index, not by the order MCC asked in: it reads 121_83's fifth scene
        // ahead of the other four, and a run is a range whatever order it arrived.
        let ordered = run.sorted { ($0.indices.last ?? 0) < ($1.indices.last ?? 0) }
        guard let start = ordered[0].indices.last else {
            throw KSPError.value("\(first.item)_\(first.param) run has no index to walk")
        }
        var total = 0
        for request in ordered {
            guard request.indices.last == start + total else {
                let broken = request.indices.last.map(String.init) ?? "none"
                throw KSPError.value(
                    "\(first.item)_\(first.param) run breaks at index \(broken), "
                        + "expected \(start + total)")
            }
            total += request.count ?? 0
        }

        let head = Array(ordered[0].indices.dropLast())
        return stride(from: 0, to: total, by: maxCount).map { offset in
            ReadRequest(
                item: first.item,
                param: first.param,
                indices: head + [start + offset],
                count: min(maxCount, total - offset)
            )
        }
    }
}
