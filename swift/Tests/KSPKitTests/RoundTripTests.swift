import Foundation
import Testing

@testable import KSPKit

/// M11 -- load a project file, re-emit it, get MCC's bytes back.
///
/// The Swift half of M3's contract, and a port of `tests/test_round_trip.py`. Byte-for-byte, with
/// one deliberate exception: the writer omits the trailing comma, so its output is strict JSON.
/// Protocol test T6.2 established MCC does not need it. Everything else -- 153,497 lines, key
/// order, tab indentation, no final newline, value formatting -- must still match exactly.
///
/// Both ports are pinned against the same third thing, MCC's bytes minus that comma, which is what
/// makes the Swift output byte-identical to the Python's without a second CLI to diff against.
@Suite struct RoundTripTests {
    /// The Python's `dumps(loads(x))`: a sample, parsed and re-emitted in MCC's order.
    ///
    /// `canonical` rather than the parsed order because a Swift `Dictionary` has none to preserve.
    /// Every sample MCC wrote is already in canonical order, so this still lands on its bytes.
    private func reemitted(_ name: String) throws -> Data {
        try Data(LenientJSON.serialise(LenientJSON.canonical(Samples.raw(name))).utf8)
    }

    @Test(arguments: Samples.names)
    func roundTripIsByteIdentical(name: String) throws {
        // The milestone, on every sample: parse and re-emit changes nothing.
        #expect(
            try firstDifference(reemitted(name), withoutTrailingComma(Samples.bytes(name))) == nil)
    }

    @Test(arguments: Samples.names)
    func outputDiffersFromMCCByExactlyTheTrailingComma(name: String) throws {
        // The bound on how far we deviate from MCC: one byte, and it is the comma. T6.2 tested the
        // comma alone; anything else drifting is a bug, and this fails on it rather than letting
        // the stripped baseline absorb it.
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
        // The temp file is renamed into place, not left beside the result.
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
        // mkstemp creates 0600 on the Python side and an atomic write is no better here, so the
        // mode is widened to the usual 0644 as the umask allows.
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
        // A second pass through the writer is a no-op.
        let once = try LenientJSON.serialise(
            LenientJSON.canonical(Samples.raw("project_5.KeyStepPro")))
        let twice = try LenientJSON.serialise(LenientJSON.canonical(LenientJSON.parse(once)))
        #expect(firstDifference(Data(twice.utf8), Data(once.utf8)) == nil)
    }

    @Test func serialiseShape() throws {
        // Tab indent, `": "` separator, no trailing comma, no final newline.
        let text = try LenientJSON.serialise([
            (key: "device", value: JSONValue.string("KeyStepPro")),
            (key: "120_101", value: JSONValue.int(127)),
        ])

        #expect(text == "{\n\t\"device\": \"KeyStepPro\",\n\t\"120_101\": 127\n}")
        #expect(!text.hasSuffix("\n"))
    }

    @Test func serialiseOfAnEmptyMapping() throws {
        // No entries, so nothing between the braces.
        #expect(try LenientJSON.serialise(RawProject()) == "{\n}")
    }

    /// What the writer emits reads back as what went in.
    ///
    /// The Python says this by parsing with `json.loads`, which is strict and so also pins the
    /// output as strict JSON -- what T6.2 bought. That half does not survive the port: neither
    /// `JSONSerialization` nor `JSONDecoder` is strict enough to reject even MCC's own trailing
    /// comma, so no Foundation parser can tell the two dialects apart. Byte identity with MCC's
    /// file, which `roundTripIsByteIdentical` holds, is what carries it here instead.
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
        // The key that drifted, rather than 153,497 of them either side of a `==`.
        #expect(original.first { reparsed[$0.key] != $0.value }?.key == nil)
    }

    /// Every shape the format has never held. Python parametrises over `1.0`, `None`, `True`, a
    /// dict and a list; the Swift type system already keeps those out of ``JSONValue``, so what
    /// reaches the writer is the ``JSONValue/other(_:)`` the reader turned them into.
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
        // On the key sequence rather than the bytes, so this says something the round trip does
        // not. A `Dictionary` hands its keys back in an arbitrary order, so every sample arrives
        // here already shuffled -- the Python has to reverse its dict to say the same thing.
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
        // M5's case: the factory template has no `version` and needs one, and appending it to a
        // dictionary leaves it nowhere in particular.
        var template = try Samples.raw("Default.KeyStepPro")
        #expect(template["version"] == nil)
        template["version"] = .string("2.5.20")

        #expect(LenientJSON.canonical(template).prefix(2).map(\.key) == ["device", "version"])
    }

    @Test func aSingleValueEditChangesExactlyOneLine() throws {
        // The desk half of M4: one changed value is one changed line. Track 3's first note is C2
        // (48) in `project_5`, hardware-confirmed in `analysis/project_5_description.txt`. Moving
        // it up a semitone must not disturb any of the other 153,496 lines.
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
