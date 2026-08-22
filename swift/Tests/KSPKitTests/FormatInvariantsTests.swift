import Foundation
import Testing

@testable import KSPKit

/// About **MCC's** bytes, never ours: when one of these fails the fix is never in the file it names.
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
        // Boost.PropertyTree, which MCC uses, tolerates the trailing comma; strict parsers do not.
        #expect(try Samples.bytes(name).suffix(3) == Data(",\n}".utf8))
    }

    @Test(arguments: Samples.names)
    func hasNoFinalNewline(name: String) throws {
        // A standard end-of-file-fixer hook appends one, which would break the round trip.
        #expect(try Samples.bytes(name).last != UInt8(ascii: "\n"), "a final newline was appended")
    }

    @Test(arguments: Samples.names)
    func declaresKeyStepProDevice(name: String) throws {
        let opening = Data("{\n\t\"device\": \"KeyStepPro\",\n".utf8)
        #expect(try Samples.bytes(name).prefix(opening.count) == opening)
    }

    @Test(arguments: Samples.names)
    func versionKeyFollowsDeviceExceptInTheFactoryTemplate(name: String) throws {
        // User saves carry `version`; MCC's factory template does not.
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
