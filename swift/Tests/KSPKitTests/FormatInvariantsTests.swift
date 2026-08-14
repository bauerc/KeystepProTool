import Foundation
import Testing

@testable import KSPKit

/// Byte-level invariants of the `.KeyStepPro` files checked into this repo, from the Swift side.
///
/// A port of `tests/test_format_invariants.py`. These files are the baseline M11's round trip is
/// measured against, so their exact bytes matter, and anything that "tidies" them -- an editor, a
/// pre-commit hook, a well-meaning formatter -- silently destroys the thing it is meant to prove.
///
/// Every assertion here is about **MCC's** output, never about ours: the trailing comma below is
/// the one the writer deliberately omits. Per `CLAUDE.md`, when one of these fails the fix is
/// never in the file it names.
///
/// One of the Python's checks has no twin here. `test_is_not_strict_json` asserts a stock parser
/// **rejects** these files, and Foundation has none that does: `JSONSerialization` and
/// `JSONDecoder` both accept MCC's trailing comma, measured on this toolchain. The Python holds
/// that premise for both ports.
@Suite struct FormatInvariantsTests {
    @Test func sampleProjectsArePresent() throws {
        let found = try FileManager.default
            .contentsOfDirectory(atPath: RepoData.projectFiles.path)
            .filter { $0.hasSuffix(".KeyStepPro") }
        #expect(found.sorted() == Samples.names.sorted())
    }

    @Test(arguments: Samples.names)
    func usesTabIndentation(name: String) throws {
        let bytes = try Samples.bytes(name)
        #expect(bytes.prefix(3) == Data("{\n\t".utf8), "expected '{' + newline + tab")
        #expect(!contains(bytes, "\n    "), "space indentation found; file was reformatted")
    }

    @Test(arguments: Samples.names)
    func hasTrailingCommaBeforeClosingBrace(name: String) throws {
        // Why `JSONSerialization` rejects these files. Boost.PropertyTree, which MCC uses,
        // tolerates it -- and T6.2 showed MCC does not need it back, which is what lets the
        // writer emit strict JSON.
        #expect(try Samples.bytes(name).suffix(3) == Data(",\n}".utf8))
    }

    @Test(arguments: Samples.names)
    func hasNoFinalNewline(name: String) throws {
        // A standard end-of-file-fixer hook appends one, which would break the round trip.
        // `.pre-commit-config.yaml` excludes `project_files/` for exactly this reason.
        #expect(try Samples.bytes(name).last != UInt8(ascii: "\n"), "a final newline was appended")
    }

    @Test(arguments: Samples.names)
    func declaresKeyStepProDevice(name: String) throws {
        let opening = Data("{\n\t\"device\": \"KeyStepPro\",\n".utf8)
        #expect(try Samples.bytes(name).prefix(opening.count) == opening)
    }

    @Test(arguments: Samples.names)
    func versionKeyFollowsDeviceExceptInTheFactoryTemplate(name: String) throws {
        // User saves carry `version`; MCC's factory template does not. M5 builds output from the
        // template, so it has to add the key -- which is `canonical`'s other job.
        let opening = Data("{\n\t\"device\": \"KeyStepPro\",\n\t\"version\": ".utf8)
        let hasVersion = try Samples.bytes(name).prefix(opening.count) == opening
        #expect(hasVersion == (name != "Default.KeyStepPro"))
    }

    @Test func groundTruthDescriptionsArePresent() throws {
        // Values verified on a physical KeyStep Pro, which cannot be regenerated without it.
        for name in ["project_5_description.txt", "project_9_tests.txt"] {
            let path = RepoData.analysis.appending(path: name).path
            #expect(FileManager.default.fileExists(atPath: path), "missing ground truth: \(path)")
            let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
            #expect(size ?? 0 > 0)
        }
    }

    private func contains(_ haystack: Data, _ needle: String) -> Bool {
        haystack.range(of: Data(needle.utf8)) != nil
    }
}
