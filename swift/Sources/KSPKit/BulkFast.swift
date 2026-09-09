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

    /// The firmware's own per-pattern flag, and the value meaning the pattern holds notes.
    /// It latches upward and never back down, so only "not 3" settles anything (spec 3.3).
    public static let dataState = 40
    public static let hasData = 3

    /// Note-indexed pool arrays an unflagged pattern settles, and the row each holds there.
    /// The step-indexed and per-pattern scalars are absent: those are settings, editable
    /// on a pattern that holds no note at all.
    public static let patternGated: [Int: Int] = [
        50: empty, 54: empty,
        109: empty, 110: empty, 111: empty, 112: empty, 113: empty,
        117: 60, 118: 7, 119: 100, 120: 49, 121: 100,
    ]

    /// Pool arrays no per-chunk gate settles, so walking across their chunks costs nothing.
    /// The melodic pool is absent deliberately: its existence array skips empty chunks
    /// outright, and a request coalesced across them would fetch what the gate had dropped.
    public static let rolledOver: Set<Int> = [53, 54, 117, 118, 119, 120, 121]

    /// Entries per middle index in a pool. A walk passing this rolls into the next chunk,
    /// and stops at the outer index (spec 7.8).
    public static let poolChunk = Constants.maxSteps

    /// A pool address as one 1-based position across the chunks of its outer index.
    public static func flat(_ indices: [Int]) -> Int {
        (indices[1] - 1) * poolChunk + indices[2]
    }

    /// The inverse of `flat`: a position back to `(outer, middle, last)`.
    public static func unflat(_ outer: Int, _ position: Int) -> [Int] {
        let (middle, last) = (position - 1).quotientAndRemainder(dividingBy: poolChunk)
        return [outer, middle + 1, last + 1]
    }

    /// Whether this request's walk carries past the end of its own chunk.
    public static func rollsOver(_ request: ReadRequest) -> Bool {
        guard let count = request.count, request.indices.count == 3 else { return false }
        return request.indices[2] + count - 1 > poolChunk
    }

    /// Track 1's phantom fourth chunk is zero-filled where the live chunks hold the
    /// default (spec 4).
    public static let phantomFill = 0

    /// What a pooled parameter holds in a pattern parameter 40 says is empty.
    public static func patternFill(param: Int, slot: Int) -> Int? {
        guard let fill = patternGated[param] else { return nil }
        return slot > Constants.poolSlots ? phantomFill : fill
    }

    /// Requests this plan expands to, against the 8,951 MCC issues.
    public static let requestCount = 3399

    /// What one pattern of one track costs: 75 pattern reads plus the index-less scalars.
    public static let patternRequestCount = 108

    /// Every address the plan covers, in as few requests as the device allows.
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

    /// Whether a request fills any key belonging to `pattern`.
    private static func covers(_ request: ReadRequest, _ pattern: Int) -> Bool {
        request.indices.first == pattern
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
            // A rolled-over param keys on the outer index alone, so its chunks join one run.
            let head =
                rolledOver.contains(request.param) && request.indices.count == 3
                ? Array(request.indices.prefix(1)) : Array(request.indices.dropLast())
            let key = RunKey(item: request.item, param: request.param, head: head)
            if let position = runs[key] {
                order[position].append(request)
            } else {
                runs[key] = order.count
                order.append([request])
            }
        }
        return try gateFirst(order).flatMap { try join($0, maxCount: maxCount) }
    }

    /// Each gate ahead of what it settles, order otherwise kept: the data state settles whole
    /// patterns, so it comes before the existence array, which settles pool chunks.
    private static func gateFirst(_ order: [[ReadRequest]]) -> [[ReadRequest]] {
        let ranked: [Int: Int] = [dataState: 0, melodicGate: 1]
        return order.filter { ranked[$0[0].param] == 0 }
            + order.filter { ranked[$0[0].param] == 1 }
            + order.filter { ranked[$0[0].param] == nil }
    }

    private static func join(_ run: [ReadRequest], maxCount: Int) throws -> [ReadRequest] {
        let first = run[0]
        guard first.count != nil else { return [first] }

        // A lone index is not a range axis: the device answers a walk over one with index 1's
        // value repeated, so the per-pattern scalars stay one request each (spec 7.8).
        if first.indices.count == 1 {
            return run.sorted { ($0.indices.last ?? 0) < ($1.indices.last ?? 0) }
        }

        if rolledOver.contains(first.param), first.indices.count == 3 {
            return try joinRolled(run, maxCount: maxCount)
        }

        // By index, not by the order MCC asked in: it reads 121_83's fifth scene
        // ahead of the other four, and a run is a range whatever order it arrived.
        let ordered = run.sorted { ($0.indices.last ?? 0) < ($1.indices.last ?? 0) }
        guard let start = ordered[0].indices.last else {
            throw KSPError.value("\(first.item)_\(first.param) run has no index to walk")
        }
        var total = 0
        for request in ordered {
            guard request.indices.last == start + total else {
                throw KSPError.value(
                    "\(first.item)_\(first.param) run breaks at \(request.indices), "
                        + "expected index \(start + total)")
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

    /// Join a run whose chunks the device walks through, flattening the middle index.
    private static func joinRolled(_ run: [ReadRequest], maxCount: Int) throws -> [ReadRequest] {
        let ordered = run.sorted { flat($0.indices) < flat($1.indices) }
        let outer = ordered[0].indices[0]
        let start = flat(ordered[0].indices)
        var total = 0
        for request in ordered {
            guard flat(request.indices) == start + total else {
                throw KSPError.value(
                    "\(request.item)_\(request.param) run breaks at \(request.indices), "
                        + "expected position \(start + total)")
            }
            total += request.count ?? 0
        }

        return stride(from: 0, to: total, by: maxCount).map { offset in
            ReadRequest(
                item: ordered[0].item,
                param: ordered[0].param,
                indices: unflat(outer, start + offset),
                count: min(maxCount, total - offset)
            )
        }
    }
}
