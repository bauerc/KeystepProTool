// Read a project off the device over CoreMIDI and write the .KeyStepPro (issues #245, #246).
//
// The transport it used to carry is now `KSPDevice`, under test; what is left here is the driver
// that #247 will replace with `ksp-swift-cli pull`. Until then this is the only way to read a
// project out of the Swift core, and the only way to exercise `KSPDevice` against the hardware.
//
//   (cd swift && swift build --target KSPDevice)
//   swiftc -O -I swift/.build/debug/Modules tools/coremidi_read.swift \
//       swift/.build/debug/KSPKit.build/*.o swift/.build/debug/KSPDevice.build/*.o \
//       -o /tmp/coremidi_read
//   /tmp/coremidi_read <slot> <out.KeyStepPro> [template.KeyStepPro]
//
// The objects rather than `-lKSPKit`: `swift build --target` compiles the target without
// archiving a library, and this tool is not a package target that SwiftPM would link for us.

import Foundation
import KSPDevice
import KSPKit

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, let slot = Int(arguments[0]) else {
    print("usage: coremidi_read <slot> <out.KeyStepPro> [template.KeyStepPro]")
    exit(2)
}
let outputPath = arguments[1]
let templatePath =
    arguments.count > 2 ? arguments[2] : "src/ksp_cli/templates/Default.KeyStepPro"

do {
    let template = try LenientJSON.load(contentsOf: URL(fileURLWithPath: templatePath))
    let (device, version) = try KeyStepPro.open()

    let started = Date()
    let raw = try BulkRead.readRaw(
        device, templateKeys: template.keys, version: version, slot: slot)
    let elapsed = Date().timeIntervalSince(started)

    try LenientJSON.write(LenientJSON.canonical(raw), to: URL(fileURLWithPath: outputPath))
    print(
        "slot \(slot): firmware \(version), \(raw.count) keys, \(device.exchanges) requests, "
            + "\(device.repairs) sentinels repaired, "
            + "\(String(format: "%.2f", elapsed))s -> \(outputPath)")
} catch {
    print("error: \(error)")
    exit(1)
}
