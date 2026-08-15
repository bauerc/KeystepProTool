import Foundation
import Testing

@testable import KSPRun

/// The factory template `convert` overwrites when the user names no `--template`.
///
/// A port of `test_the_bundled_template_is_the_factory_default` in `tests/test_convert_cli.py`,
/// and the check that the resource actually made it into the bundle: SwiftPM copies a symlink *as
/// a symlink*, so the real bytes live under `Sources/KSPRun/Resources/` and the Python's
/// `src/ksp_cli/templates/` copy is the link. If that ever inverts, this fails on the first read.
@Suite struct TemplateTests {
    @Test func theBundledTemplateIsTheFactoryDefault() throws {
        let bundled = try #require(ConvertRunner.defaultTemplate())
        let sample = RepoData.projectFiles.appending(path: "Default.KeyStepPro")
        #expect(try Data(contentsOf: bundled) == Data(contentsOf: sample))
    }

    /// The same file the Python ships, reached the way the Python reaches it.
    ///
    /// They are the same file for a reason: the sample is what every format test is written
    /// against, and the copy is what a user's conversion starts from.
    @Test func thePythonAndSwiftTemplatesAreOneFile() throws {
        let bundled = try #require(ConvertRunner.defaultTemplate())
        let shipped = RepoData.root.appending(path: "src/ksp_cli/templates/Default.KeyStepPro")
        #expect(try Data(contentsOf: bundled) == Data(contentsOf: shipped))
    }
}
