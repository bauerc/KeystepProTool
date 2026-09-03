import Foundation
import Testing

@testable import KSPKit

private func addresses(_ requests: [ReadRequest]) throws -> [String] {
    try requests.flatMap(BulkRead.keysFor)
}

/// The pattern a track key belongs to, read off the key itself.
private func patternOf(_ name: String) -> Int? {
    let parts = name.split(separator: "_")
    return parts.count > 2 ? Int(parts[2]) : nil
}

/// `tests/fixtures/bulk_fast_requests.txt`, written by `ksp.bulk_fast.iter_requests`.
private func pythonPlan() throws -> [ReadRequest] {
    let path = RepoData.fixtures.appending(path: "bulk_fast_requests.txt")
    return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map { line in
        let fields = line.split(separator: " ")
        guard fields.count == 4 else {
            throw KSPError.value("\(line) is not <item> <param> <indices> <count>")
        }
        return ReadRequest(
            item: try number(fields[0]),
            param: try number(fields[1]),
            indices: fields[2] == "-" ? [] : try fields[2].split(separator: ",").map(number),
            count: fields[3] == "-" ? nil : try number(fields[3])
        )
    }
}

private func number(_ field: Substring) throws -> Int {
    guard let value = Int(field) else { throw KSPError.value("\(field) is not a number") }
    return value
}

@Suite struct BulkFastTests {
    @Test func theSequenceIsThePythonPlanRequestForRequest() throws {
        // The whole contract of the port: the same frames, in the same order, or a device read
        // written against one core desyncs against the other.
        let produced = try BulkFast.iterRequests()
        let expected = try pythonPlan()

        #expect(produced.count == expected.count)
        let mismatch = zip(produced, expected).enumerated().first { $0.element.0 != $0.element.1 }
        if let mismatch {
            Issue.record(
                """
                request \(mismatch.offset)
                  produced: \(mismatch.element.0)
                  expected: \(mismatch.element.1)
                """)
        }
    }

    @Test func thePlanDeclaresItsOwnLength() throws {
        #expect(try BulkFast.iterRequests().count == BulkFast.requestCount)
        #expect(BulkFast.requestCount == 2044)
    }

    @Test func thePlanAddressesEveryKeyExactlyOnce() throws {
        // 117,783 is what MCC's own 8,951 requests cover. Fewer frames, not fewer addresses.
        let covered = try addresses(try BulkFast.iterRequests())

        #expect(covered.count == 117_783)
        #expect(Set(covered).count == 117_783)
    }

    @Test func everyRequestIsOneTheDeviceAnswers() throws {
        // A count above 100 comes back clamped and would read as a desync; four indices draw
        // no reply at all.
        for request in try BulkFast.iterRequests() {
            _ = try Sysex.buildReadRequest(request)
            if let count = request.count {
                #expect((1...3).contains(request.indices.count))
                #expect(0 < count && count <= Sysex.maxReadCount)
            }
        }
    }

    @Test func noRunInThePlanIsLongerThanASingleRequest() throws {
        // The extent binds before the protocol does: the longest contiguous run is a 64-entry
        // pool chunk, well inside the 100 the device honours.
        #expect(try BulkFast.iterRequests().map { $0.count ?? 0 }.max() == 64)
    }

    @Test func theExistenceArrayIsReadBeforeTheNotesItGates() throws {
        // Without this the gate has nothing to consult -- MCC's leaf order puts 50 after the
        // parameters it settles.
        var seenGate: Set<[Int]> = []
        for request in try BulkFast.iterRequests() where request.indices.count == 3 {
            guard request.count != nil else { continue }
            let pool = [request.item, request.indices[0], request.indices[1]]
            if request.param == BulkFast.melodicGate {
                seenGate.insert(pool)
            } else if BulkFast.melodicGated.contains(request.param) {
                #expect(seenGate.contains(pool))
            }
        }
    }

    @Test func theDrumPoolIsNeverGated() throws {
        // A dead drum entry reads 127 in some patterns and the default row in others, so
        // nothing derives it -- 117-121 must stay out of the gated set.
        #expect(BulkFast.melodicGated.isDisjoint(with: Set(117...121)))
        #expect(BulkFast.melodicGated == [109, 110, 111, 112, 113])
        #expect(BulkFast.melodicGate == 50)
        #expect(BulkFast.empty == 127)
    }

    @Test(arguments: [1, 5, 16])
    func thePatternWalkCoversEveryKeyOfThatPattern(pattern: Int) throws {
        // H2.4 reads one pattern of one track, and must not quietly drop a key the full walk
        // would have filled for it.
        let whole = try addresses(try BulkFast.iterRequests())
        let subset = Set(
            try addresses(try BulkFast.iterPatternRequests(item: 123, pattern: pattern)))
        let owed = Set(
            whole.filter { $0.hasPrefix("123_") && patternOf($0) == pattern })

        #expect(owed.isSubset(of: subset))
        // The per-pattern scalars ride in one 16-entry range, so neighbouring patterns come
        // along; no other track's pattern data may. The index-less track scalars are kept.
        #expect(
            !subset.contains {
                ["124_", "125_", "126_"].contains(where: $0.hasPrefix) && patternOf($0) != nil
            })
    }

    @Test(arguments: [1, 5, 16])
    func thePatternWalkReadsTheScalarsThatMakeAPatternPlay(pattern: Int) throws {
        // Step count, swing, pattern bits and data state are per-pattern scalars coalesced
        // into one range at index 1.
        let names = Set(
            try addresses(try BulkFast.iterPatternRequests(item: 123, pattern: pattern)))
        let owed: Set = [
            "123_40_\(pattern)", "123_97_\(pattern)", "123_98_\(pattern)",
            "123_99_\(pattern)", "123_100_\(pattern)",
        ]

        #expect(owed.isSubset(of: names))
    }

    @Test func thePatternWalkCarriesTheIndexLessScalars() throws {
        // Tempo lives in 120_70/71/72 and has no pattern index, so a walk that kept only
        // indexed requests would export the pattern at the wrong speed.
        let names = Set(try addresses(try BulkFast.iterPatternRequests(item: 123, pattern: 1)))

        #expect(Set(["120_70", "120_71", "120_72"]).isSubset(of: names))
        #expect(names.contains("123_40_1"))
    }

    @Test func thePatternWalkIsAFractionOfTheWhole() throws {
        let requests = try BulkFast.iterPatternRequests(item: 123, pattern: 1)

        #expect(requests.count == BulkFast.patternRequestCount)
        #expect(BulkFast.patternRequestCount == 115)
        #expect(requests.count < BulkFast.requestCount / 16)
    }

    @Test func thePatternWalkStillReadsTheGateBeforeTheNotes() throws {
        // Filtering must not disturb the order the gate depends on.
        var seenGate = false
        for request in try BulkFast.iterPatternRequests(item: 123, pattern: 1)
        where request.indices.count == 3 {
            guard request.count != nil else { continue }
            if request.param == BulkFast.melodicGate {
                seenGate = true
            } else if BulkFast.melodicGated.contains(request.param) {
                #expect(seenGate)
            }
        }
    }

    @Test func aSmallerCeilingSplitsTheSameAddresses() throws {
        // The ceiling is the protocol's, not the plan's: halve it and the plan asks twice as
        // often for exactly the addresses it asked for before.
        let split = try BulkFast.iterRequests(maxCount: 32)

        #expect(try addresses(split) == addresses(try BulkFast.iterRequests()))
        #expect(split.map { $0.count ?? 0 }.max() == 32)
        #expect(split.count > BulkFast.requestCount)
    }

    @Test(arguments: [0, -1])
    func aCeilingBelowOneIsRefused(maxCount: Int) {
        let thrown = #expect(throws: KSPError.self) {
            try BulkFast.iterRequests(maxCount: maxCount)
        }
        #expect(thrown == .value("maxCount \(maxCount), expected 1 or more"))
    }
}
