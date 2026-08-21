import ArgumentParser
import Foundation

struct RootCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ksp-swift-cli",
        abstract: "Convert between Standard MIDI files and Arturia KeyStep Pro projects.",
        subcommands: [Dump.self, Export.self, Convert.self])

    func run() throws {
        // The help is what the user needs, so it goes to stdout -- but no command at all is a
        // usage error and leaves with 2.
        print(Self.helpMessage())
        throw ExitStatus(code: 2)
    }
}

/// The codes are load-bearing and shared with the Python CLI: **0 success, 1 file or format
/// failure, 2 usage failure**.
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
            // `--help` arrives here as a clean exit; everything else is a usage error, which
            // ArgumentParser would give 64 (EX_USAGE), so the code is remapped.
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
