import Foundation
import Testing

@Suite struct ExitCodeTests {
    @Test func aGoodRunSucceeds() throws {
        #expect(try Self.run(["dump", Self.project]).code == 0)
    }

    @Test func helpIsSuccessOnStdout() throws {
        let result = try Self.run(["--help"])
        #expect(result.code == 0)
        #expect(result.stdout.contains("SUBCOMMANDS:"))
    }

    @Test func aMissingFileIsOne() throws {
        let result = try Self.run(["dump", "/nonexistent/nope.KeyStepPro"])
        #expect(result.code == 1)
        #expect(result.stderr.hasPrefix("ksp-swift-cli dump:"))
    }

    @Test func anOutOfRangeSelectionIsTwo() throws {
        let result = try Self.run(["dump", Self.project, "--track", "9"])
        #expect(result.code == 2)
        #expect(result.stderr.contains("'--track' must be in 1...4"))
    }

    @Test func aMalformedExportSelectionIsTwo() throws {
        let result = try Self.run(["export", Self.project, "--tracks", "bad"])
        #expect(result.code == 2)
        #expect(
            result.stderr == "ksp-swift-cli export: --tracks: 'bad' is not a number or a range\n")
    }

    @Test(arguments: ["0", "11"]) func aRepeatCountOutsideItsRangeIsTwo(_ count: String) throws {
        let result = try Self.run(["export", Self.project, "--repeat", count])
        #expect(result.code == 2)
        #expect(result.stderr == "ksp-swift-cli export: repeat must be 1-10\n")
    }

    @Test func flatVelocityFreshSucceeds() throws {
        // --dry-run: this runs against the real fixture, so nothing here may write beside it.
        #expect(
            try Self.run(["export", Self.project, "--flat-velocity", "fresh", "--dry-run"]).code
                == 0)
    }

    @Test func flatVelocityNeitherFreshNorANumberIsTwo() throws {
        let result = try Self.run(["export", Self.project, "--flat-velocity", "loud"])
        #expect(result.code == 2)
        #expect(
            result.stderr
                == "ksp-swift-cli export: --flat-velocity: 'loud' is not 'fresh' or a velocity\n")
    }

    @Test(arguments: ["0", "128"]) func flatVelocityOutsideItsRangeIsTwo(_ value: String) throws {
        let result = try Self.run(["export", Self.project, "--flat-velocity", value])
        #expect(result.code == 2)
        #expect(
            result.stderr
                == "ksp-swift-cli export: flat_velocity must be 1-127; "
                + "0 is a MIDI note-off, not a silent note\n")
    }

    @Test func anUnknownOptionIsTwo() throws {
        // Not 64, which is what ArgumentParser exits with if the entry point stops mapping.
        let result = try Self.run(["dump", Self.project, "--nope"])
        #expect(result.code == 2)
        #expect(result.stderr.contains("Unknown option '--nope'"))
    }

    @Test func noSubcommandIsTwo() throws {
        #expect(try Self.run([]).code == 2)
    }

    static let project = RepoData.projectFiles.appending(path: "project_5.KeyStepPro").path

    /// From the package directory, not `Bundle`: under the CLT `Bundle.main` is the swiftpm helper.
    static let executable: URL = {
        let build = RepoData.root.appending(path: "swift/.build")
        let debug = build.appending(path: "debug/ksp-swift-cli")
        return FileManager.default.isExecutableFile(atPath: debug.path)
            ? debug : build.appending(path: "release/ksp-swift-cli")
    }()

    static func run(_ arguments: [String]) throws -> (code: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // No personal ~/.config drum map: the run has to mean the same thing on every machine.
        process.environment = ["HOME": FileManager.default.temporaryDirectory.path]

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read before waiting: a pipe that fills up would deadlock the child.
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            process.terminationStatus, String(decoding: stdout, as: UTF8.self),
            String(decoding: stderr, as: UTF8.self)
        )
    }
}
