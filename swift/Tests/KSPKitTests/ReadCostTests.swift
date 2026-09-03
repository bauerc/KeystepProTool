import Foundation
import KSPKit
import Testing

/// What reading a project costs in the Swift core, phase by phase, as one JSON line on stdout.
/// Gated so `swift test` and `./scripts/validate.sh` never pay for it; `./scripts/bench_read.sh`
/// sets the variables. Deliberately does not use `Samples`, which memoises what is being measured.
@Suite(
    .disabled(
        if: ProcessInfo.processInfo.environment["KSP_BENCH"] == nil,
        "set KSP_BENCH=1, or run ./scripts/bench_read.sh"))
struct ReadCostTests {
    static let defaultSample = "project_5.KeyStepPro"
    static let defaultReps = 5
    static let tracksPerProject = 4

    struct Rep {
        let readBytes: Double
        let parseJSON: Double
        let decode: Double
        let repeatLoad: Double

        var total: Double { readBytes + parseJSON + decode }
    }

    @Test func reportsWhatOneReadCosts() throws {
        let floor = Self.peakResidentBytes()
        let environment = ProcessInfo.processInfo.environment
        let name = environment["KSP_BENCH_FILE"] ?? Self.defaultSample
        let reps = environment["KSP_BENCH_REPS"].flatMap(Int.init) ?? Self.defaultReps
        let url = RepoData.projectFiles.appending(path: name)

        Reader.cacheClear()  // so the warm-up is genuinely cold whatever ran before it
        _ = try Self.oneRep(url)  // discarded warm-up
        var samples: [Rep] = []
        for _ in 0..<reps { samples.append(try Self.oneRep(url)) }

        let project = try Reader.readProject(
            try LenientJSON.load(contentsOf: url), sourceName: name)
        #expect(project.tracks.count == Self.tracksPerProject)

        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let peak = Self.peakResidentBytes()
        print(
            Self.line(
                name: name, size: size, reps: reps, samples: samples, floor: floor, peak: peak))
    }

    /// One read with nothing warm, then a second `Reader.load` of the same path -- a `ReadCache`
    /// hit since #238. The phases bypass it, so they still time the parser rather than the cache.
    private static func oneRep(_ url: URL) throws -> Rep {
        let start = ContinuousClock.now
        let data = try Data(contentsOf: url)
        let afterBytes = ContinuousClock.now
        let raw = try LenientJSON.parse(data)
        let afterJSON = ContinuousClock.now
        let project = try Reader.readProject(raw, sourceName: url.lastPathComponent)
        let afterDecode = ContinuousClock.now

        let beforeRepeat = ContinuousClock.now
        let repeated = try Reader.load(contentsOf: url)
        let afterRepeat = ContinuousClock.now
        #expect(repeated.device == project.device)

        return Rep(
            readBytes: elapsed(start, afterBytes),
            parseJSON: elapsed(afterBytes, afterJSON),
            decode: elapsed(afterJSON, afterDecode),
            repeatLoad: elapsed(beforeRepeat, afterRepeat))
    }

    private static func elapsed(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant)
        -> Double
    {
        let components = (to - from).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func peakResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size_max : 0
    }

    /// `{"min": ..., "median": ...}`, the median averaged over two for an even count as
    /// `statistics.median` does, so the two cores' figures mean the same thing.
    private static func spread(_ values: [Double]) -> String {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        let median =
            sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return "{\"min\": \(sorted[0]), \"median\": \(median)}"
    }

    /// The same keys `tools/bench_read.py --json` emits, so `--render` tables the two together.
    private static func line(
        name: String, size: Int, reps: Int, samples: [Rep], floor: UInt64, peak: UInt64
    ) -> String {
        #if DEBUG
            let configuration = "debug"
        #else
            let configuration = "release"
        #endif
        #if arch(arm64)
            let machine = "arm64"
        #else
            let machine = "x86_64"
        #endif

        let fields = [
            "\"core\": \"swift\"",
            "\"file\": \"\(name)\"",
            "\"size_bytes\": \(size)",
            "\"reps\": \(reps)",
            "\"read_bytes_s\": \(spread(samples.map(\.readBytes)))",
            "\"parse_json_s\": \(spread(samples.map(\.parseJSON)))",
            "\"decode_s\": \(spread(samples.map(\.decode)))",
            "\"total_s\": \(spread(samples.map(\.total)))",
            "\"repeat_load_s\": \(spread(samples.map(\.repeatLoad)))",
            "\"rss_peak_bytes\": \(peak)",
            "\"rss_ratio\": \(Double(peak - floor) / Double(size))",
            "\"rss_floor_bytes\": \(floor)",
            "\"runtime\": \"Swift, \(configuration) build\"",
            "\"platform\": \"\(ProcessInfo.processInfo.operatingSystemVersionString) \(machine)\"",
        ]
        return "{" + fields.joined(separator: ", ") + "}"
    }
}
