import KSPKit

/// CoreMIDI cuts a reply at the first `0xFF` and delivers the terminator anyway (spec 7.9.1).
/// `0xFF` is System Reset and also the device's unset sentinel, so the frame arrives well-formed,
/// echoing its address and the count it honoured, while carrying fewer values than it promised.
enum Sentinel {
    /// A long request ends `<last index> <count> F7`, and its reply repeats the request's
    /// header byte for byte in place of that terminator.
    private static let countFromEnd = 2
    private static let indexFromEnd = 3

    /// How many values a long reply arrived with when it is short of its promise, nil when whole.
    static func shortfall(of reply: [UInt8], to request: [UInt8]) -> Int? {
        guard reply.count > 6, reply[6] == Sysex.cmdReadReply,
            request.count > indexFromEnd
        else { return nil }
        let carried = reply.count - request.count
        return carried < promise(of: request) ? carried : nil
    }

    /// The whole reply, rebuilt: the value after the ones that arrived is the sentinel, and the
    /// rest is re-read from the next index on. One `reread` per sentinel.
    static func repair(
        _ request: [UInt8],
        _ reply: [UInt8],
        carried: Int,
        reread: ([UInt8]) throws -> [UInt8]
    ) throws -> (frame: [UInt8], repairs: Int) {
        let promised = promise(of: request)
        let first = Int(request[request.count - indexFromEnd])
        let head = request.count - 1

        var values = Array(reply.dropFirst(head).dropLast())
        values.append(UInt8(Sysex.unset))
        var repairs = 1

        var next = carried + 1
        while next < promised {
            let tail = try rest(of: request, from: first + next, count: promised - next)
            let answer = try reread(tail)
            let arrived = answer.count - tail.count
            values.append(contentsOf: answer.dropFirst(tail.count - 1).dropLast())
            guard arrived < promised - next else { break }
            values.append(UInt8(Sysex.unset))
            repairs += 1
            next += arrived + 1
        }
        return (Array(reply.prefix(head)) + values + [Sysex.end], repairs)
    }

    private static func promise(of request: [UInt8]) -> Int {
        Int(request[request.count - countFromEnd])
    }

    /// The same request re-addressed past a sentinel.
    private static func rest(of request: [UInt8], from index: Int, count: Int) throws -> [UInt8] {
        guard let index = UInt8(exactly: index), let count = UInt8(exactly: count) else {
            throw DeviceError.confused(
                "re-reading \(count) values from index \(index) does not fit in a SysEx frame")
        }
        var tail = request
        tail[tail.count - indexFromEnd] = index
        tail[tail.count - countFromEnd] = count
        return tail
    }
}
