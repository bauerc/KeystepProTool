import Foundation
import Testing

/// The `midi_parity` cases the Python refused as usage failures, held to its frozen answer. The
/// rest of each gate's cases run through the runners in `KSPRunTests`.
@Suite struct ReferenceTests {
    @Test func everyRefusalHasAReference() {
        #expect(Refusal.recorded.count == 175)
    }

    @Test(arguments: Refusal.recorded) func refusal(_ reference: Refusal) throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "ksp-reference-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let (command, output) =
            switch reference.direction {
            case "import": ("convert", directory.appending(path: "out.KeyStepPro").path)
            case "split": ("export", directory.path + "/")
            default: ("export", directory.appending(path: "out.mid").path)
            }
        let result = try ExitCodeTests.run(
            [command] + reference.inputs + reference.flags + ["-o", output], in: RepoData.root)

        func scrubbed(_ text: String) -> String {
            text.replacingOccurrences(of: directory.path + "/", with: "<out>/")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    let prog = "ksp-swift-cli \(command): "
                    return line.hasPrefix(prog) ? "<prog>: " + line.dropFirst(prog.count) : line
                }
                .joined(separator: "\n")
        }
        #expect(result.code == reference.exit, "\(reference.label): the exit code")
        #expect(scrubbed(result.stdout) == reference.stdout, "\(reference.label): stdout")
        #expect(scrubbed(result.stderr) == reference.stderr, "\(reference.label): stderr")
    }
}

struct Refusal: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let direction: String
    let inputs: [String]
    let flags: [String]
    let exit: Int32
    let stdout: String
    let stderr: String

    static let recorded: [Refusal] = {
        let directory = RepoData.fixtures.appending(path: "reference/midi_parity")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            try? JSONDecoder().decode(
                Refusal.self, from: Data(contentsOf: directory.appending(path: name)))
        }
        .filter { $0.exit == 2 }
    }()

    var testDescription: String { label }
}
