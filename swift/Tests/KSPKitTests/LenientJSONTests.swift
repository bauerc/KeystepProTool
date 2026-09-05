import Foundation
import Testing

@testable import KSPKit

@Suite struct LenientJSONTests {
    @Test func parsesATrailingCommaBeforeAClosingBrace() throws {
        #expect(try LenientJSON.parse("{\n\t\"a\": 1,\n}") == ["a": .int(1)])
    }

    @Test func parsesAFileWithoutATrailingComma() throws {
        // Strict JSON still has to work -- MCC's dialect is a superset.
        #expect(try LenientJSON.parse("{\"a\": 1}") == ["a": .int(1)])
    }

    @Test func leavesCommasInsideStringsAlone() throws {
        #expect(
            try LenientJSON.parse("{\"name\": \"kick, snare\"}") == ["name": .string("kick, snare")]
        )
    }

    @Test func rejectsJSONThatIsNotAnObject() {
        let thrown = #expect(throws: KSPError.self) { try LenientJSON.parse("[1, 2, 3]") }
        #expect(thrown == .value("expected a JSON object, got list"))
    }

    @Test(arguments: [("null", "NoneType"), ("42", "int"), ("1.5", "float"), ("\"x\"", "str")])
    func namesWhatItGotInstead(text: String, typeName: String) {
        let thrown = #expect(throws: KSPError.self) { try LenientJSON.parse(text) }
        #expect(thrown == .value("expected a JSON object, got \(typeName)"))
    }

    @Test func saysSoWhenTheTextIsNotJSONAtAll() throws {
        let thrown = try #require(
            #expect(throws: KSPError.self) { try LenientJSON.parse("{\"a\": ") })
        #expect(thrown.description.hasPrefix("could not parse: "))
    }

    /// `JSONDecoder` reported all of these as one sentence with no position; the scan says where.
    @Test(
        arguments: [
            ("{", "expected a key or }"),
            ("{\"a\"", "expected :"),
            ("{\"a\": ", "expected a value"),
            ("{\"a\": 1", "expected , or }"),
            ("{\"a\" 1}", "expected :"),
            ("{\"a\": nope}", "expected null"),
            ("{\"a\": 1} junk", "trailing content"),
            ("{1: 2}", "expected a quoted string"),
            ("{\"a\": \"x", "never closed"),
            ("{\"a\": \"x\\q\"}", "not a JSON escape"),
            ("{\"a\": \"x\\u00\"}", "cut short"),
            ("{\"a\": \"x\\uzzzz\"}", "hex digits"),
            ("{\"a\": \"x\\ud83dy\"}", "no low surrogate"),
            ("{\"a\": [1, 2}", "expected , or }"),
        ])
    func namesWhatItFoundAndWhereMalformedInputBroke(text: String, reason: String) throws {
        let thrown = try #require(#expect(throws: KSPError.self) { try LenientJSON.parse(text) })
        #expect(thrown.description.hasPrefix("could not parse: "))
        #expect(thrown.description.contains(reason), "\(text) said \(thrown.description)")
        #expect(thrown.description.contains(" at byte "))
    }

    /// The writer emits all of these (`JSONNode.quoted`), so the reader has to take them back.
    @Test(
        arguments: [
            ("\\\"", "\""), ("\\\\", "\\"), ("\\/", "/"), ("\\b", "\u{08}"), ("\\f", "\u{0C}"),
            ("\\n", "\n"), ("\\r", "\r"), ("\\t", "\t"), ("\\u0041", "A"), ("\\u00e9", "é"),
            ("\\ud83d\\ude00", "😀"),
        ])
    func takesBackEveryEscapeTheWriterEmits(escape: String, decoded: String) throws {
        #expect(try LenientJSON.parse("{\"a\": \"x\(escape)y\"}") == ["a": .string("x\(decoded)y")])
        #expect(try LenientJSON.parse("{\"x\(escape)y\": 1}") == ["x\(decoded)y": .int(1)])
    }

    @Test func readsAnEmptyObject() throws {
        #expect(try LenientJSON.parse("{}") == [:])
        #expect(try LenientJSON.parse("{\n}") == [:])
    }

    /// A nested value is walked only to find its end, so the entries after it still arrive.
    @Test func keepsReadingPastAValueTheFormatNeverHolds() throws {
        let raw = try LenientJSON.parse("{\"a\": {\"b\": [1, {\"c\": \"}\"}]}, \"d\": 2}")
        #expect(raw["a"] == .other("dict"))
        #expect(raw["d"] == .int(2))
    }

    /// Python's dict, and so `orjson`'s, keeps the last of a repeated key.
    @Test func aRepeatedKeyKeepsItsLastValue() throws {
        #expect(try LenientJSON.parse("{\"a\": 1, \"a\": 2}") == ["a": .int(2)])
    }

    /// No `Int` holds these, and the reader names them the way Python's parser would.
    @Test(arguments: ["1.5", "1e3", "-2.5e-3", "99999999999999999999"])
    func aNumberNoIntegerHoldsIsAFloat(text: String) throws {
        #expect(try LenientJSON.parse("{\"a\": \(text)}") == ["a": .other("float")])
    }

    @Test(arguments: [("0", 0), ("-5", -5), ("153495", 153_495)])
    func readsTheIntegersTheFormatIsMadeOf(text: String, value: Int) throws {
        #expect(try LenientJSON.parse("{\"a\": \(text)}") == ["a": .int(value)])
    }

    @Test(arguments: [
        ("{\"a\": 1,\n}", "{\"a\": 1\n}"),
        ("{\"a\": 1}", "{\"a\": 1}"),
        // Only the comma a closing brace follows: MCC writes exactly one.
        ("{\"a\": [1, 2, ], \"b\": 3}", "{\"a\": [1, 2, ], \"b\": 3}"),
        ("{\"a\": \"x,\"}", "{\"a\": \"x,\"}"),
    ])
    func strippingTouchesOnlyMCCsTrailingComma(text: String, expected: String) {
        let stripped = LenientJSON.strippingTrailingComma(Data(text.utf8))
        #expect(String(decoding: stripped, as: UTF8.self) == expected)
    }

    @Test func aValueTheFormatNeverHoldsKeepsItsPythonTypeName() throws {
        let raw = try LenientJSON.parse("{\"a\": 1.5, \"b\": true, \"c\": null, \"d\": [1]}")
        #expect(raw["a"] == .other("float"))
        #expect(raw["b"] == .other("bool"))
        #expect(raw["c"] == .other("NoneType"))
        #expect(raw["d"] == .other("list"))
    }

    @Test func loadsEverySampleProject() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: RepoData.projectFiles.path)
            .filter { $0.hasSuffix(".KeyStepPro") }.sorted()
        #expect(!names.isEmpty)

        for name in names {
            let raw = try LenientJSON.load(contentsOf: RepoData.projectFiles.appending(path: name))
            #expect(raw["device"] == .string("KeyStepPro"))
            // The numeric key set is fixed at 153,495, plus "device" and, in user saves, "version".
            #expect([153_496, 153_497].contains(raw.count), "\(name) has \(raw.count) keys")
        }
    }

    @Test func aSampleProjectHoldsIntegersUnderEveryNumericKey() throws {
        let raw = try LenientJSON.load(
            contentsOf: RepoData.projectFiles.appending(path: "project_5.KeyStepPro"))
        let strings = raw.filter { if case .string = $0.value { true } else { false } }
        #expect(Set(strings.keys) == ["device", "version"])
        #expect(raw["version"] == .string(Constants.projectVersion))
    }
}
