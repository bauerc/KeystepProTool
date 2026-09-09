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

    /// Each gate reads before what it settles: the data state settles whole patterns, so it
    /// comes before the existence array, which settles pool chunks. Everything else follows.
    public static let gateRank: [Int: Int] = [dataState: 0, melodicGate: 1]

    /// What each address holds in a pattern the data state says is empty, keyed by parameter
    /// and how many indices it takes -- the arity is what separates the control track's step
    /// arrays from the note pools, and no parameter settles at two arities. The per-pattern
    /// scalars are absent: those are settings, editable on a pattern that holds no note at all.
    /// 96 is the skip mask's "all four sequences".
    public static let dataStateGated: [Address: Int] = [
        Address(90, 2): 0, Address(91, 2): 0, Address(92, 2): 0, Address(93, 2): 0,
        Address(94, 2): 0, Address(95, 2): 0, Address(96, 2): 15,
        Address(50, 3): empty, Address(54, 3): empty,
        Address(109, 3): empty, Address(110, 3): empty, Address(111, 3): empty,
        Address(112, 3): empty, Address(113, 3): empty,
        Address(117, 3): 60, Address(118, 3): 7, Address(119, 3): 100,
        Address(120, 3): 49, Address(121, 3): 100,
    ]

    /// A parameter and the number of indices it takes, which together say what it addresses.
    public struct Address: Hashable, Sendable {
        let param: Int
        let arity: Int

        init(_ param: Int, _ arity: Int) {
            self.param = param
            self.arity = arity
        }
    }

    /// Pool arrays no per-chunk gate settles, so walking across their chunks costs nothing.
    /// The melodic pool is absent deliberately: its existence array skips empty chunks
    /// outright, and a request coalesced across them would fetch what the gate had dropped.
    /// A walk passing a chunk rolls into the next one, and stops at the outer index (spec 7.8).
    public static let rolledOver: Set<Int> = [53, 54, 117, 118, 119, 120, 121]

    /// Whether this request addresses a pool the device walks across its chunks.
    public static func rolled(_ request: ReadRequest) -> Bool {
        rolledOver.contains(request.param) && request.indices.count == 3
    }

    /// A pool address as one 1-based position across the chunks of its outer index.
    public static func flat(_ indices: [Int]) -> Int {
        (indices[1] - 1) * Constants.maxSteps + indices[2]
    }

    /// The inverse of `flat`: a position back to `(outer, middle, last)`.
    public static func unflat(_ outer: Int, _ position: Int) -> [Int] {
        let (middle, last) = (position - 1).quotientAndRemainder(dividingBy: Constants.maxSteps)
        return [outer, middle + 1, last + 1]
    }

    /// What this address holds in a pattern parameter 40 says is empty, or `nil` where
    /// parameter 40 settles nothing for it.
    public static func dataStateFill(_ request: ReadRequest) -> Int? {
        guard let fill = dataStateGated[Address(request.param, request.indices.count)] else {
            return nil
        }
        guard request.indices.count == 3 else { return fill }
        // Track 1's phantom fourth chunk is zero-filled where the live chunks hold the
        // default (spec 4).
        return request.indices[1] > Constants.poolSlots ? 0 : fill
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
                rolled(request)
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

    /// Each gate ahead of what it settles, order otherwise kept -- `sorted` is not stable in
    /// Swift, so the original position breaks the tie and mirrors Python's stable sort.
    private static func gateFirst(_ order: [[ReadRequest]]) -> [[ReadRequest]] {
        func rank(_ run: [ReadRequest]) -> Int { gateRank[run[0].param] ?? gateRank.count }
        return order.enumerated()
            .sorted {
                rank($0.element) == rank($1.element)
                    ? $0.offset < $1.offset : rank($0.element) < rank($1.element)
            }
            .map(\.element)
    }

    private static func join(_ run: [ReadRequest], maxCount: Int) throws -> [ReadRequest] {
        let first = run[0]
        guard first.count != nil else { return [first] }

        // A lone index is not a range axis: the device answers a walk over one with index 1's
        // value repeated, so the per-pattern scalars stay one request each (spec 7.8).
        if first.indices.count == 1 {
            return run.sorted { ($0.indices.last ?? 0) < ($1.indices.last ?? 0) }
        }

        // A rolled-over pool counts across its chunks; every other run walks its last index.
        // Both are constant across a run, which is what the run key was built from.
        let isRolled = rolled(first)
        let outer = first.indices[0]
        let head = Array(first.indices.dropLast())
        func position(_ indices: [Int]) -> Int {
            isRolled ? flat(indices) : (indices.last ?? 0)
        }
        func rebuild(_ at: Int) -> [Int] { isRolled ? unflat(outer, at) : head + [at] }

        // By index, not by the order MCC asked in: it reads 121_83's fifth scene
        // ahead of the other four, and a run is a range whatever order it arrived.
        let ordered = run.sorted { position($0.indices) < position($1.indices) }
        let start = position(ordered[0].indices)
        var total = 0
        for request in ordered {
            guard position(request.indices) == start + total else {
                throw KSPError.value(
                    "\(first.item)_\(first.param) run breaks at position "
                        + "\(position(request.indices)), expected \(start + total)")
            }
            total += request.count ?? 0
        }

        return stride(from: 0, to: total, by: maxCount).map { offset in
            ReadRequest(
                item: first.item,
                param: first.param,
                indices: rebuild(start + offset),
                count: min(maxCount, total - offset)
            )
        }
    }
}
