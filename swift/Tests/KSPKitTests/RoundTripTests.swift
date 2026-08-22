import Foundation
import Testing

@testable import KSPKit

/// Byte-for-byte against MCC with one deliberate exception: the writer omits the trailing comma.
@Suite struct RoundTripTests {
    /// `canonical` rather than the parsed order, because a `Dictionary` has none to preserve.
    private func reemitted(_ name: String) throws -> Data {
        try Data(LenientJSON.serialise(LenientJSON.canonical(Samples.raw(name))).utf8)
    }

    @Test(arguments: Samples.names)
    func roundTripIsByteIdentical(name: String) throws {
        #expect(
            try firstDifference(reemitted(name), withoutTrailingComma(Samples.bytes(name))) == nil)
    }

    @Test(arguments: Samples.names)
    func outputDiffersFromMCCByExactlyTheTrailingComma(name: String) throws {
        // The bound on the deviation from MCC: one byte, and it is the comma.
        let original = try Samples.bytes(name)
        let emitted = try reemitted(name)

        #expect(original.count - emitted.count == 1)
        #expect(firstDifference(emitted.dropLast(2), original.dropLast(3)) == nil)
        #expect(emitted.suffix(2) == Data("\n}".utf8))
    }

    @Test(arguments: Samples.names)
    func writeProducesIdenticalBytes(name: String) throws {
        // Through the filesystem, where a platform could translate newlines.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: name)

        try LenientJSON.write(LenientJSON.canonical(Samples.raw(name)), to: destination)

        let written = try Data(contentsOf: destination)
        #expect(try firstDifference(written, withoutTrailingComma(Samples.bytes(name))) == nil)
    }

    @Test func writeReplacesAnExistingFileAndLeavesNoDebris() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "out.KeyStepPro")
        try Data("stale".utf8).write(to: destination)

        let project: RawProject = ["device": .string("KeyStepPro"), "120_37": .int(3)]
        try LenientJSON.write(LenientJSON.canonical(project), to: destination)

        #expect(
            try String(contentsOf: destination, encoding: .utf8)
                == "{\n\t\"device\": \"KeyStepPro\",\n\t\"120_37\": 3\n}")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                == ["out.KeyStepPro"])
    }

    @Test func writtenFilesAreReadableByTheUserWhoWillOpenThemInMCC() throws {
        // An atomic write leaves 0600, so the mode is widened to the usual 0644 as umask allows.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "out.KeyStepPro")

        try LenientJSON.write(
            [(key: "device", value: JSONValue.string("KeyStepPro"))], to: destination)

        let mask = umask(0)
        umask(mask)
        let mode =
            try FileManager.default.attributesOfItem(atPath: destination.path)[
                .posixPermissions] as? Int
        #expect(mode == Int(0o666 & ~mask))
    }

    @Test func serialiseIsIdempotent() throws {
        let once = try LenientJSON.serialise(
            LenientJSON.canonical(Samples.raw("project_5.KeyStepPro")))
        let twice = try LenientJSON.serialise(LenientJSON.canonical(LenientJSON.parse(once)))
        #expect(firstDifference(Data(twice.utf8), Data(once.utf8)) == nil)
    }

    @Test func serialiseShape() throws {
        let text = try LenientJSON.serialise([
            (key: "device", value: JSONValue.string("KeyStepPro")),
            (key: "120_101", value: JSONValue.int(127)),
        ])

        #expect(text == "{\n\t\"device\": \"KeyStepPro\",\n\t\"120_101\": 127\n}")
        #expect(!text.hasSuffix("\n"))
    }

    @Test func serialiseOfAnEmptyMapping() throws {
        #expect(try LenientJSON.serialise(RawProject()) == "{\n}")
    }

    @Test func aSmallMappingParsesBackToItself() throws {
        let project: RawProject = [
            "device": .string("KeyStepPro"), "120_37": .int(3), "126_99_2": .int(20),
        ]
        let emitted = try LenientJSON.serialise(LenientJSON.canonical(project))
        #expect(try LenientJSON.parse(emitted) == project)
    }

    @Test func aWholeProjectParsesBackToItself() throws {
        let name = "user_empty_project.KeyStepPro"
        let original = try Samples.raw(name)
        let reparsed = try LenientJSON.parse(reemitted(name))

        #expect(reparsed.count == original.count)
        // Names the key that drifted, rather than 153,497 of them either side of a `==`.
        #expect(original.first { reparsed[$0.key] != $0.value }?.key == nil)
    }

    /// The type system keeps these out of ``JSONValue``, so they reach the writer as `other(_:)`.
    @Test(arguments: ["float", "bool", "NoneType", "list", "dict"])
    func serialiseRejectsValuesTheFirmwareHasNeverSeen(shape: String) throws {
        #expect {
            try LenientJSON.serialise(["120_37": JSONValue.other(shape)])
        } throws: { error in
            error as? KSPError == .type("120_37 holds \(shape), expected int or str")
        }
    }

    @Test(arguments: Samples.names)
    func canonicalRestoresMCCKeyOrder(name: String) throws {
        // A `Dictionary` hands its keys back arbitrarily, so every sample arrives here shuffled.
        let asMCCWroteThem = try String(decoding: Samples.bytes(name), as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                line.firstIndex(of: "\"").flatMap { open in
                    line[line.index(after: open)...].firstIndex(of: "\"").map {
                        String(line[line.index(after: open)..<$0])
                    }
                }
            }

        let ours = try LenientJSON.canonical(Samples.raw(name)).map(\.key)

        #expect(ours.count == asMCCWroteThem.count)
        #expect(
            zip(ours, asMCCWroteThem).enumerated()
                .first { $0.element.0 != $0.element.1 }
                .map { "key \($0.offset): \($0.element.0), MCC wrote \($0.element.1)" } == nil)
    }

    @Test func canonicalSortsNumericKeysAsStrings() {
        // `126_99_16` before `126_99_2` -- a numeric sort would disagree.
        let ordered = LenientJSON.canonical([
            "126_99_2": .int(20), "126_99_16": .int(20), "126_99_13": .int(20),
        ])
        #expect(ordered.map(\.key) == ["126_99_13", "126_99_16", "126_99_2"])
    }

    @Test func canonicalPlacesAnInjectedVersionSecond() throws {
        // The factory template has no `version`, and appending one leaves it nowhere in particular.
        var template = try Samples.raw("Default.KeyStepPro")
        #expect(template["version"] == nil)
        template["version"] = .string("2.5.20")

        #expect(LenientJSON.canonical(template).prefix(2).map(\.key) == ["device", "version"])
    }

    @Test func aSingleValueEditChangesExactlyOneLine() throws {
        // Track 3's first note is C2 (48) in `project_5`, hardware-confirmed.
        var project = try Samples.raw("project_5.KeyStepPro")
        let pitchKey = Keys.key(125, Constants.pSeqPitch, 1, 1, 1)
        #expect(project[pitchKey] == .int(48))
        project[pitchKey] = .int(49)

        let original = try String(
            decoding: withoutTrailingComma(Samples.bytes("project_5.KeyStepPro")), as: UTF8.self)
        let edited = try LenientJSON.serialise(LenientJSON.canonical(project))
        let changed = zip(original.split(separator: "\n"), edited.split(separator: "\n"))
            .filter { $0 != $1 }

        #expect(changed.count == 1)
        #expect(changed.first.map { String($0.0) } == "\t\"\(pitchKey)\": 48,")
        #expect(changed.first.map { String($0.1) } == "\t\"\(pitchKey)\": 49,")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "ksp-round-trip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
