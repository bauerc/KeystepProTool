// Measure what reading a `.KeyStepPro` project costs, phase by phase: requirement D1's evidence.
//
// Compiled against KSPKit by scripts/bench_read.sh, which runs it once per sample so that a peak
// memory figure belongs to one file. `<file> [--reps N] [--json]`, or `--render` over --json lines.

import Foundation

// `@main` rather than top-level code: swiftc allows that only in a file called `main.swift`.
@main
enum BenchRead {
    /// One `ReadCache` hit is below the clock's resolution, so it is timed in a batch.
    static let repeatCalls = 1000

    static let columns: [(key: String, heading: String)] = [
        ("read_bytes_s", "bytes"),
        ("parse_json_s", "json"),
        ("decode_s", "decode"),
        ("total_s", "total"),
        ("repeat_load_s", "repeat"),
    ]

    struct BenchError: Error, CustomStringConvertible {
        let description: String
    }

    static func seconds(_ duration: Duration) -> Double {
        let (whole, attoseconds) = duration.components
        return Double(whole) + Double(attoseconds) / 1e18
    }

    /// One uncached read, phase by phase, then the repeat `load` that hits `ReadCache`.
    static func oneRep(_ url: URL) throws -> [String: Double] {
        Reader.clearCache()
        let clock = ContinuousClock()
        let start = clock.now
        let data = try Data(contentsOf: url)
        let afterBytes = clock.now
        let raw = try LenientJSON.parse(data)
        let afterJSON = clock.now
        let project = try Reader.readProject(raw, sourceName: url.lastPathComponent)
        let afterDecode = clock.now

        let repeated = try Reader.load(contentsOf: url)
        let beforeRepeat = clock.now
        for _ in 0..<repeatCalls {
            _ = try Reader.load(contentsOf: url)
        }
        let afterRepeat = clock.now
        guard repeated == project, project.tracks.count == 4 else {
            throw BenchError(description: "\(url.lastPathComponent): the repeated load disagrees")
        }

        let bytes = seconds(afterBytes - start)
        let json = seconds(afterJSON - afterBytes)
        let decode = seconds(afterDecode - afterJSON)
        return [
            "read_bytes_s": bytes,
            "parse_json_s": json,
            "decode_s": decode,
            "total_s": bytes + json + decode,
            "repeat_load_s": seconds(afterRepeat - beforeRepeat) / Double(repeatCalls),
        ]
    }

    // ru_maxrss is bytes on Darwin, kilobytes on Linux.
    static func rssBytes() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    static func measure(_ url: URL, reps: Int, floor: Int) throws -> [String: Any] {
        _ = try oneRep(url)  // discarded warm-up
        let samples = try (0..<reps).map { _ in try oneRep(url) }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        let peak = rssBytes()

        var reading: [String: Any] = [
            "core": "swift",
            "file": url.lastPathComponent,
            "size_bytes": size,
            "reps": reps,
            "rss_peak_bytes": peak,
            "rss_floor_bytes": floor,
            "rss_ratio": Double(peak - floor) / Double(size),
            "runtime": "swiftc -O",
        ]
        for column in columns {
            let values = samples.map { $0[column.key] ?? 0 }
            reading[column.key] = ["min": values.min() ?? 0, "median": median(values)]
        }
        return reading
    }

    /// Milliseconds, kept to three significant figures down to the cache hit's 50 ns.
    static func milliseconds(_ seconds: Double) -> String {
        let value = seconds * 1e3
        if value >= 1 { return String(format: "%.2f", value) }
        return String(format: value >= 0.001 ? "%.4f" : "%.6f", value)
    }

    static func padded(_ text: String, _ width: Int, left: Bool = false) -> String {
        let fill = String(repeating: " ", count: max(0, width - text.count))
        return left ? text + fill : fill + text
    }

    static func phase(_ reading: [String: Any], _ key: String, _ figure: String) -> Double {
        (reading[key] as? [String: Double])?[figure] ?? 0
    }

    static func human(_ reading: [String: Any]) -> [String] {
        let size = Double(reading["size_bytes"] as? Int ?? 0)
        var lines = [
            "\(reading["file"] ?? "")  (\(String(format: "%.2f", size / 1e6)) MB, "
                + "\(reading["reps"] ?? 0) reps)"
        ]
        for column in columns {
            lines.append(
                "  \(padded(column.heading, 7, left: true)) min "
                    + "\(padded(milliseconds(phase(reading, column.key, "min")), 10)) ms   median "
                    + "\(padded(milliseconds(phase(reading, column.key, "median")), 10)) ms")
        }
        let peak = Double(reading["rss_peak_bytes"] as? Int ?? 0) / 1e6
        let floor = Double(reading["rss_floor_bytes"] as? Int ?? 0) / 1e6
        lines.append(
            "  rss peak    \(String(format: "%7.2f", peak)) MB   = "
                + "\(String(format: "%.2f", reading["rss_ratio"] as? Double ?? 0)) over a "
                + "\(String(format: "%.2f", floor)) MB runtime floor")
        return lines
    }

    /// Medians in milliseconds, one row per file.
    static func render(_ readings: [[String: Any]]) -> [String] {
        let head = columns.map { padded($0.heading, 11) }.joined()
        var lines = [
            padded("file", 28, left: true) + padded("size", 8) + head + padded("rss/byte", 10),
            String(repeating: "-", count: 28 + 8 + head.count + 10),
        ]
        for reading in readings {
            let size = Double(reading["size_bytes"] as? Int ?? 0) / 1e6
            let times = columns.map { padded(milliseconds(phase(reading, $0.key, "median")), 11) }
            lines.append(
                padded(reading["file"] as? String ?? "", 28, left: true)
                    + padded(String(format: "%.2fM", size), 8) + times.joined()
                    + padded(String(format: "%.2f", reading["rss_ratio"] as? Double ?? 0), 10))
        }
        lines.append("")
        lines.append("Times are medians in milliseconds. rss/byte is the process peak above the")
        lines.append("runtime floor, per byte of file.")
        return lines
    }

    static func usage() -> Never {
        FileHandle.standardError.write(
            Data("usage: bench_read <file> [--reps N] [--json] | bench_read --render\n".utf8))
        exit(2)
    }

    static func main() throws {
        let floor = rssBytes()
        var arguments = Array(CommandLine.arguments.dropFirst())

        if arguments == ["--render"] {
            let input = String(
                decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            let readings = try input.split(separator: "\n").compactMap {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            for line in render(readings) {
                print(line)
            }
            return
        }

        var reps = 5
        var json = false
        if let flag = arguments.firstIndex(of: "--json") {
            json = true
            arguments.remove(at: flag)
        }
        if let flag = arguments.firstIndex(of: "--reps") {
            guard flag + 1 < arguments.count, let count = Int(arguments[flag + 1]), count >= 1
            else { usage() }
            reps = count
            arguments.removeSubrange(flag...(flag + 1))
        }
        guard arguments.count == 1 else { usage() }

        let reading = try measure(URL(filePath: arguments[0]), reps: reps, floor: floor)
        if json {
            let line = try JSONSerialization.data(withJSONObject: reading, options: [.sortedKeys])
            print(String(decoding: line, as: UTF8.self))
        } else {
            for line in human(reading) {
                print(line)
            }
        }
    }
}
