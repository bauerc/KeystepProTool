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
