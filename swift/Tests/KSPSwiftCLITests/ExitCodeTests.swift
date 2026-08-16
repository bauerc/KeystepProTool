import Foundation
import Testing

/// The exit codes, asserted against the built binary rather than against ``DumpRunner``.
///
/// They are load-bearing and shared with the Python CLI -- **0 success, 1 file or format failure,
/// 2 usage failure** -- and the mapping from a parser error to 2 lives in the `@main` entry point,
/// which nothing else reaches. ArgumentParser's own default for a usage error is 64, so this is
/// the test that would catch the entry point being replaced by a plain `main()`.
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

    /// Export's selection is parsed in the command body rather than by `validate()`, so that the
    /// wording matches `ksp2midi`'s; this is the test that it still leaves through exit code 2.
    @Test func aMalformedExportSelectionIsTwo() throws {
        let result = try Self.run(["export", Self.project, "--tracks", "bad"])
        #expect(result.code == 2)
        #expect(
            result.stderr == "ksp-swift-cli export: --tracks: 'bad' is not a number or a range\n")
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

    // MARK: - Running it

    static let project = RepoData.projectFiles.appending(path: "project_5.KeyStepPro").path

    /// Where SwiftPM put the executable.
    ///
    /// Resolved from the package directory rather than from `Bundle`: under the Command Line
    /// Tools, Swift Testing's process is the `swiftpm` helper, so `Bundle.main` points into the
    /// toolchain and `allBundles` never sees the `.xctest` beside the binary.
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
