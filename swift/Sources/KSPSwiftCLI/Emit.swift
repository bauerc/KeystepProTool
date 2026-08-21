import ArgumentParser
import Foundation
import KSPRun

extension ParsableCommand {
    /// The one place the CLI turns a ``RunResult`` back into streams and an exit status.
    func emit(_ result: RunResult) throws {
        if !result.stdout.isEmpty { print(result.stdout) }
        if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
        if result.code != 0 { throw ExitStatus(code: result.code) }
    }
}
