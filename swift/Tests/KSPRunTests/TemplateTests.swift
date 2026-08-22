import Foundation
import Testing

@testable import KSPRun

/// SwiftPM copies a symlink *as a symlink*, so the real bytes live under `KSPRun/Resources/`.
@Suite struct TemplateTests {
    @Test func theBundledTemplateIsTheFactoryDefault() throws {
        let bundled = try #require(ConvertRunner.defaultTemplate())
        let sample = RepoData.projectFiles.appending(path: "Default.KeyStepPro")
        #expect(try Data(contentsOf: bundled) == Data(contentsOf: sample))
    }

    @Test func thePythonAndSwiftTemplatesAreOneFile() throws {
        let bundled = try #require(ConvertRunner.defaultTemplate())
        let shipped = RepoData.root.appending(path: "src/ksp_cli/templates/Default.KeyStepPro")
        #expect(try Data(contentsOf: bundled) == Data(contentsOf: shipped))
    }
}
