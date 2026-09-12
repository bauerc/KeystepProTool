// Write the coalesced read plan as one hex frame a line, for `coremidi_probe replay` (issue #245).
//
// Standalone on purpose, like the probe it feeds: it compiles KSPKit's sources directly rather
// than linking the package, so a hardware session needs no built product.
//
//   swiftc -O swift/Sources/KSPKit/*.swift tools/read_plan.swift -o /tmp/read_plan
//   /tmp/read_plan [slot] > /tmp/plan.txt

import Foundation

// `@main` rather than top-level code: swiftc allows that only in a file called `main.swift`.
@main
struct ReadPlan {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let slot = arguments.first.flatMap(Int.init) ?? 1
        do {
            for request in try BulkFast.iterRequests() {
                let frame = try Sysex.buildReadRequest(request, slot: slot)
                print(frame.map { ($0 < 0x10 ? "0" : "") + String($0, radix: 16) }.joined())
            }
        } catch {
            FileHandle.standardError.write(Data("read_plan: \(error)\n".utf8))
            exit(1)
        }
    }
}
