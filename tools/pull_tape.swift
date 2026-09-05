// The Swift core's pull, over a captured exchange instead of the device.
//
// Usage: pulltape <tape.txt> <slot> <template.KeyStepPro> <out.KeyStepPro>. Compiled against
// KSPKit and KSPTape by scripts/pull_parity.sh, which is the only caller: `ksp-swift-cli pull`
// opens the hardware, and the gate has to run where there is none.

import Foundation

// `@main` rather than top-level code: swiftc allows that only in a file called `main.swift`.
@main
enum PullTape {
    static func main() throws {
        let arguments = CommandLine.arguments
        let device = TapeDevice(try tapeValues(contentsOf: URL(filePath: arguments[1])))
        let template = try LenientJSON.load(contentsOf: URL(filePath: arguments[3]))
        let raw = try BulkRead.readRaw(
            device, templateKeys: template.keys, version: BulkRead.defaultVersion,
            slot: Int(arguments[2]) ?? Sysex.defaultSlot)
        try LenientJSON.write(LenientJSON.canonical(raw), to: URL(filePath: arguments[4]))
    }
}
