import ArgumentParser
import Foundation

/// The headless face of the port, so M9-M12 are testable long before M13's GUI exists.
///
/// `dump` landed with M10; `export` and `convert` follow at M12, each as its own `ParsableCommand`
/// in its own file, mounted here -- the same shape `ksp_cli`'s `register(app)` gives the Python,
/// where a command is written once and reached two ways.
struct RootCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ksp-swift-cli",
        abstract: "Convert between Standard MIDI files and Arturia KeyStep Pro projects.",
        subcommands: [Dump.self, Export.self])

    func run() throws {
        // Matching the Python group, which is built with `no_args_is_help`: the help is what the
        // user needs so it goes to stdout, but invoking the tool with no command at all is a usage
        // error and leaves with 2.
        print(Self.helpMessage())
        throw ExitStatus(code: 2)
    }
}

/// A failure carrying the exit code to leave with.
///
/// The codes are load-bearing and shared with the Python CLI: **0 success, 1 file or format
/// failure, 2 usage failure**. ArgumentParser's own default for a usage error is 64, which is why
/// the entry point below maps them itself rather than calling `main()`.
struct ExitStatus: Error {
    let code: Int32
}

@main
enum Entry {
    static func main() {
        do {
            var command = try RootCommand.parseAsRoot()
            try command.run()
        } catch let status as ExitStatus {
            // Already reported by whoever threw it.
            exit(status.code)
        } catch {
            // `--help` arrives here as a clean exit, which is success and belongs on stdout;
            // everything else is a usage error. ArgumentParser would give those 64 (EX_USAGE), so
            // the code is remapped rather than taken from `exitCode(for:)`.
            let message = RootCommand.fullMessage(for: error)
            if RootCommand.exitCode(for: error) == .success {
                print(message)
                exit(0)
            }
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(2)
        }
    }
}
