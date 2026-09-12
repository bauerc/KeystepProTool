public protocol Transport {
    func exchange(_ request: [UInt8]) throws -> [UInt8]

    /// Write a frame the device does not answer. Only the prologue is one.
    func send(_ frame: [UInt8]) throws
}

/// Reading a whole project off the device into the flat dictionary a file parses to.
public enum BulkRead {
    public static let deviceName = "KeyStepPro"

    /// From the identity reply; nothing in the read protocol itself supplies it.
    public static let defaultVersion = "2.5.20"

    /// Padding past the end of two short arrays; 127 is what the corpus holds (spec 3.4).
    public static let mccConstants = ["120_55_5": 127, "120_56_4": 127, "120_56_5": 127]

    /// What a read returns for an empty slot. Well-formed, so no codec catches it.
    public static let filler = 0x7F

    /// Tells a filler read from a real one: no corpus file holds the filler byte here.
    public static let slotProbe = "120_37"

    /// A long read walks its last index forward by `count`; the others are fixed.
    public static func keysFor(_ request: ReadRequest) throws -> [String] {
        guard let count = request.count else {
            return [Keys.key(request.item, request.param)]
        }
        guard let last = request.indices.last else {
            throw KSPError.value("\(request) is a long read with no index to walk")
        }
        if BulkFast.rollsOver(request) {
            let (outer, start) = (request.indices[0], BulkFast.flat(request.indices))
            return (0..<count).map {
                Keys.key(request.item, request.param, indices: BulkFast.unflat(outer, start + $0))
            }
        }
        let head = Array(request.indices.dropLast())
        return (0..<count).map {
            Keys.key(request.item, request.param, indices: head + [last + $0])
        }
    }

    /// `templateKeys` supplies the full key set; the plan addresses the logical extent only.
    public static func readRaw<Names: Sequence>(
        _ transport: any Transport,
        templateKeys: Names,
        version: String = defaultVersion,
        slot: Int = Sysex.defaultSlot
    ) throws -> RawProject where Names.Element == String {
        // The prologue is what selects the slot: without it, byte 7 is ignored and the read
        // returns whichever project the last prologue named, silently and in full.
        try transport.send(Sysex.prologue(slot))

        var values = try walkFast(transport, slot: slot)
        values.merge(mccConstants) { _, constant in constant }

        let leading = Set(LenientJSON.leadingKeys)
        for name in templateKeys where !leading.contains(name) && values[name] == nil {
            values[name] = 0
        }

        var result: RawProject = ["device": .string(deviceName), "version": .string(version)]
        for (name, value) in values {
            result[name] = .int(value)
        }
        return result
    }

    private static func walkFast(_ transport: any Transport, slot: Int) throws -> [String: Int] {
        var seen: [String: Int] = [:]
        for request in try BulkFast.iterRequests() {
            let names = try keysFor(request)
            let settled = alreadyAnswered(request, seen)
            let values =
                try settled.map { Array(repeating: $0, count: names.count) }
                ?? fetch(transport, request, slot: slot)
            guard values.count == names.count else {
                throw KSPError.value(
                    "\(request) answered \(values.count) values, expected \(names.count)")
            }
            for (name, value) in zip(names, values) {
                try refuseFiller(name, value, slot: slot)
                seen[name] = value
            }
        }
        return seen
    }

    private static func fetch(
        _ transport: any Transport, _ request: ReadRequest, slot: Int
    ) throws -> [Int] {
        let frame = try transport.exchange(Sysex.buildReadRequest(request, slot: slot))
        let (answered, values) = try Sysex.parseReply(frame)
        guard answered == request else {
            throw KSPError.value("asked for \(request), device answered \(answered)")
        }
        // A reply about another project would merge two of them into one file.
        let echoed = try Sysex.parseSlot(frame)
        guard echoed == slot else {
            throw KSPError.value("asked slot \(slot), device answered slot \(echoed)")
        }
        return values.map { $0 == Sysex.unset ? Sysex.unsetInFile : $0 }
    }

    /// `poolSlot` is the note pool's own middle index, not the project slot.
    private static func poolGate(_ request: ReadRequest, _ poolSlot: Int, count: Int) -> [String] {
        let pattern = request.indices[0]
        let first = request.indices[2]
        return (0..<count).map {
            Keys.key(request.item, BulkFast.melodicGate, indices: [pattern, poolSlot, first + $0])
        }
    }

    /// Whether parameter 40 has been read for this pattern and says it holds no note.
    private static func patternSettlesEmpty(_ request: ReadRequest, _ seen: [String: Int]) -> Bool {
        let name = Keys.key(
            request.item, Constants.pPatternDataState, indices: [request.indices[0]])
        guard let flag = seen[name] else { return false }
        return flag != Constants.patternHasData
    }

    /// The pattern data state settles a pooled param outright; the rest is the melodic pool
    /// (spec 3).
    private static func alreadyAnswered(_ request: ReadRequest, _ seen: [String: Int]) -> Int? {
        guard let count = request.count else { return nil }
        if request.indices.count > 1, let fill = BulkFast.dataStateFill[request.param],
            patternSettlesEmpty(request, seen)
        {
            return fill
        }
        guard request.indices.count == 3 else { return nil }
        if BulkFast.melodicGated.contains(request.param) {
            let gate = poolGate(request, request.indices[1], count: count)
            return gate.allSatisfy { seen[$0] == BulkFast.empty } ? BulkFast.empty : nil
        }
        if request.param == BulkFast.melodicGate, request.indices[1] > 1 {
            let previous = poolGate(request, request.indices[1] - 1, count: count)
            if previous.contains(where: { seen[$0] == BulkFast.empty }) { return BulkFast.empty }
        }
        return nil
    }

    /// A whole dump of filler parses as a valid, empty project, so nothing below notices.
    private static func refuseFiller(_ name: String, _ value: Int, slot: Int) throws {
        guard name == slotProbe, value == filler else { return }
        throw KSPError.value(
            "the device answered \(slotProbe) with \(Sysex.hexByte(UInt8(filler))), "
                + "the filler byte, rather "
                + "than a value any project holds: it is not returning slot \(slot)'s contents. "
                + "The usual cause is slot \(slot) never having been saved on the device.")
    }
}
