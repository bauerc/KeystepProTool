import ArgumentParser
import Foundation
import KSPDevice
import KSPKit
import KSPRun

struct Pull: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull",
        abstract: "Read a project off an attached KeyStep Pro into a .KeyStepPro file.",
        discussion: """
            The device must be connected over USB and powered on, and MIDI Control Center must be \
            closed -- it holds the same interface. --slot chooses which of the sixteen projects is \
            read and needs no help from the panel, but it is read as saved, so save any panel \
            edits first.
            """)

    @Argument(help: "destination .KeyStepPro file", completion: .file())
    var output: String

    @Option(help: "project slot to read, as numbered on the device")
    var slot = Sysex.defaultSlot

    @Flag(
        name: .customLong("no-identity"),
        help: """
            skip the identity request and write version \(BulkRead.defaultVersion) instead of \
            asking the device for it
            """)
    var noIdentity = false

    @Option(
        name: .customLong("timeout"),
        help: ArgumentHelp("how long to wait for each reply", valueName: "MS"))
    var timeoutMs = DeviceTransport.defaultTimeoutMs

    @Option(
        help: """
            project supplying the file's full key set (default: the shipped factory default). The \
            read plan addresses the logical extent only; the rest is zero
            """, completion: .file())
    var template: String?

    @Flag(name: .customLong("force"), help: "overwrite an existing output file")
    var force = false

    @Flag(
        name: .customLong("quiet"),
        help: "suppress the stdout summary. Warnings still go to stderr")
    var quiet = false

    @Flag(
        name: [.short, .long], help: "list every diagnostic instead of one summary line per kind")
    var verbose = false

    func validate() throws {
        if !(1...Constants.projectSlots ~= slot) {
            throw ValidationError("'--slot' must be in 1...\(Constants.projectSlots)")
        }
        if timeoutMs < 1 {
            throw ValidationError("'--timeout' must be at least 1")
        }
    }

    func run() throws {
        let result = PullRunner.run(
            PullRunner.Options(
                output: URL(filePath: output), slot: slot, noIdentity: noIdentity,
                timeoutMs: timeoutMs, template: template.map { URL(filePath: $0) },
                force: force, quiet: quiet, verbose: verbose))
        try emit(result)
    }
}
