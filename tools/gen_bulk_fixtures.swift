// Regenerate fixtures/bulk_fast_requests.txt and fixtures/bulk_read_walk.txt from the Swift plan.
//
// Compiled against KSPKit and KSPTape by scripts/gen_bulk_fixtures.sh, the only caller. BulkFastTests
// and BulkReadTests hold the code to these files, so rewriting them is a reviewed decision.

import Foundation

// `@main` rather than top-level code: swiftc allows that only in a file called `main.swift`.
@main
enum GenBulkFixtures {
    /// One request as `<item> <param> <indices|-> <count|->`.
    static func line(_ request: ReadRequest) -> String {
        let indices =
            request.indices.isEmpty ? "-" : request.indices.map(String.init).joined(separator: ",")
        let count = request.count.map(String.init) ?? "-"
        return "\(request.item) \(request.param) \(indices) \(count)\n"
    }

    static func write(_ requests: [ReadRequest], to path: String) throws {
        try requests.map(line).joined().write(toFile: path, atomically: true, encoding: .utf8)
        print("wrote \(path): \(requests.count) requests")
    }

    static func main() throws {
        try write(try BulkFast.iterRequests(), to: "fixtures/bulk_fast_requests.txt")

        let tape = try tapeValues(contentsOf: URL(filePath: "fixtures/recall_tape.txt"))
        let device = TapeDevice(tape)
        _ = try BulkRead.readRaw(device, templateKeys: [String]())
        try write(device.asked, to: "fixtures/bulk_read_walk.txt")
    }
}
