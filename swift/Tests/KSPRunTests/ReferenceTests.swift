import Foundation
import KSPKit
import KSPRun
import KSPTape
import Testing

/// Every case the four parity gates ran, held to the Python's frozen answer in `fixtures/reference`.
@Suite struct ReferenceTests {
    @Test func everyGateCaseHasAReference() {
        #expect(DumpCase.all.count == 12)
        #expect(WriterCase.all.count == 6)
        #expect(MidiCase.all.count == 431)
        #expect(PullCase.all.count == 2)
    }

    @Test(arguments: DumpCase.all) func dump(_ reference: DumpCase) throws {
        let project = URL(filePath: "project_files/\(reference.project)", relativeTo: RepoData.root)
        let result = DumpRunner.run(
            DumpRunner.Options(
                path: project, asJSON: reference.asJSON, configPath: noPersonalConfig))
        let expected = try String(contentsOf: reference.expected, encoding: .utf8)
        if let line = firstDifferingLine(printed(result), expected) {
            Issue.record("\(reference.testDescription): the dump differs at \(line)")
        }
    }

    @Test(arguments: WriterCase.all) func writer(_ reference: WriterCase) throws {
        try inScratch { directory in
            let written = directory.appending(path: reference.project)
            let raw = try LenientJSON.load(
                contentsOf: RepoData.projectFiles.appending(path: reference.project))
            try LenientJSON.write(LenientJSON.canonical(raw), to: written)
            try expectArtifact(written, reference.artifact, case: reference.project)
        }
    }

    @Test(arguments: MidiCase.throughTheRunners) func conversion(_ reference: MidiCase) throws {
        try inScratch { directory in
            let result = try reference.run(into: directory)
            #expect(result.code == reference.exit, "\(reference.label): the exit code")
            let streams = [
                ("stdout", printed(result), reference.stdout),
                ("stderr", result.stderr, reference.stderr),
            ]
            for (stream, produced, expected) in streams {
                let produced = scrubbed(produced, directory: directory, prog: reference.prog)
                if let line = firstDifferingLine(produced, expected) {
                    Issue.record("\(reference.label): \(stream) differs at \(line)")
                }
            }

            // A shared refusal has no artifact to compare, and that is a pass, not a skip.
            guard reference.exit == 0, result.code == 0 else { return }
            let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(
                written.sorted() == reference.artifacts.keys.sorted(),
                "\(reference.label): the files written")
            for (name, artifact) in reference.artifacts where written.contains(name) {
                try expectArtifact(
                    directory.appending(path: name), artifact, case: reference.label)
            }
        }
    }

    @Test(arguments: PullCase.all) func pull(_ reference: PullCase) throws {
        let device = TapeDevice(
            try tapeValues(contentsOf: RepoData.fixtures.appending(path: reference.tape)))
        let template = RepoData.root.appending(
            path: "swift/Sources/KSPRun/Resources/Default.KeyStepPro")
        try inScratch { directory in
            // --no-identity: the version is the one thing a tape cannot answer for.
            let result = PullRunner.run(
                PullRunner.Options(
                    output: directory.appending(path: "pulled_\(reference.slot).KeyStepPro"),
                    slot: reference.slot, noIdentity: true, template: template, alsoMidi: true,
                    quiet: true, configPath: noPersonalConfig),
                attach: { device })
            #expect(result.code == 0, "\(reference.testDescription): \(result.stderr)")
            for (name, artifact) in reference.artifacts {
                try expectArtifact(
                    directory.appending(path: name), artifact, case: reference.testDescription)
            }
        }
    }
}
