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

    @Test func theBundledTemplateIsTheResourceFile() throws {
        let bundled = try #require(ConvertRunner.defaultTemplate())
        let resource = RepoData.root.appending(
            path: "swift/Sources/KSPRun/Resources/Default.KeyStepPro")
        #expect(try Data(contentsOf: bundled) == Data(contentsOf: resource))
    }

    /// A throwaway tree shaped like the one `scripts/bundle_app.sh` assembles.
    private static func laidOut(executable: String, resource: String) throws -> (
        root: URL, executable: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "template-location-\(UUID().uuidString)")
        let binary = root.appending(path: executable)
        let template = root.appending(path: resource)
        for directory in [binary, template].map({ $0.deletingLastPathComponent() }) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        try Data().write(to: binary)
        try Data("template".utf8).write(to: template)
        return (root, binary)
    }

    @Test func itFindsTheTemplateInAnAppBundlesResources() throws {
        let laid = try Self.laidOut(
            executable: "App.app/Contents/MacOS/kspplus",
            resource: "App.app/Contents/Resources/KeyStepProTool_KSPRun.bundle/Default.KeyStepPro")
        defer { try? FileManager.default.removeItem(at: laid.root) }

        let found = try #require(TemplateLocation.find(forExecutableAt: laid.executable))

        #expect(try Data(contentsOf: found) == Data("template".utf8))
    }

    @Test func itLooksInsideAMacOSStyleResourceBundle() throws {
        let laid = try Self.laidOut(
            executable: "App.app/Contents/MacOS/kspplus",
            resource: "App.app/Contents/Resources/Packed.bundle/Contents/Resources/"
                + "Default.KeyStepPro")
        defer { try? FileManager.default.removeItem(at: laid.root) }

        let found = try #require(TemplateLocation.find(forExecutableAt: laid.executable))

        #expect(try Data(contentsOf: found) == Data("template".utf8))
    }

    @Test func itFollowsASymlinkOntoTheRealBinary() throws {
        let laid = try Self.laidOut(
            executable: "App.app/Contents/MacOS/kspplus",
            resource: "App.app/Contents/Resources/KeyStepProTool_KSPRun.bundle/Default.KeyStepPro")
        defer { try? FileManager.default.removeItem(at: laid.root) }
        let binDirectory = laid.root.appending(path: "bin")
        try FileManager.default.createDirectory(
            at: binDirectory, withIntermediateDirectories: true)
        let link = binDirectory.appending(path: "kspplus")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: laid.executable)

        let found = try #require(TemplateLocation.find(forExecutableAt: link))

        #expect(try Data(contentsOf: found) == Data("template".utf8))
    }

    @Test func itFindsABundleBesideALooseBinary() throws {
        let laid = try Self.laidOut(
            executable: "release/kspplus",
            resource: "release/KeyStepProTool_KSPRun.bundle/Default.KeyStepPro")
        defer { try? FileManager.default.removeItem(at: laid.root) }

        let found = try #require(TemplateLocation.find(forExecutableAt: laid.executable))

        #expect(try Data(contentsOf: found) == Data("template".utf8))
    }

    @Test func itFindsNothingWhereNoBundleSits() throws {
        let laid = try Self.laidOut(
            executable: "release/kspplus", resource: "elsewhere/Default.KeyStepPro")
        defer { try? FileManager.default.removeItem(at: laid.root) }

        #expect(TemplateLocation.find(forExecutableAt: laid.executable) == nil)
    }
}
