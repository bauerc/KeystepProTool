import Testing

@testable import KSPKit

/// The dump's `--json` has to come out byte-identical to the Python's, so the serialiser is
/// pinned against `json.dumps(..., indent=2)` rather than against what merely looks like valid
/// JSON. `JSONEncoder` cannot do this: it sorts or synthesises key order, and it renders `120.0`
/// as `120`.
@Suite struct JSONNodeTests {
    @Test func scalarsRenderAsPythonWritesThem() {
        #expect(JSONNode.null.serialised() == "null")
        #expect(JSONNode.bool(true).serialised() == "true")
        #expect(JSONNode.bool(false).serialised() == "false")
        #expect(JSONNode.int(-3).serialised() == "-3")
    }

    @Test func anIntegralDoubleKeepsItsPoint() {
        // The whole reason for a hand-written serialiser: tempo 120.0 and gate 1.0 are floats on
        // the Python side and print as `120.0`, where `JSONEncoder` would print `120`.
        #expect(JSONNode.double(120).serialised() == "120.0")
        #expect(JSONNode.double(0.0625).serialised() == "0.0625")
        #expect(JSONNode.double(132.5).serialised() == "132.5")
    }

    @Test func keysKeepTheOrderTheyWereGivenIn() {
        // Insertion order, because that is what a Python dict has, and the Python CLI's output is
        // the thing this has to match.
        let node = JSONNode.object([("b", .int(1)), ("a", .int(2))])
        #expect(node.serialised() == "{\n  \"b\": 1,\n  \"a\": 2\n}")
    }

    @Test func emptyContainersStayOnOneLine() {
        #expect(JSONNode.object([]).serialised() == "{}")
        #expect(JSONNode.array([]).serialised() == "[]")
    }

    @Test func nestingIndentsByTwoPerLevel() {
        let node = JSONNode.object([("xs", .array([.int(1), .object([("y", .null)])]))])
        #expect(
            node.serialised() == """
                {
                  "xs": [
                    1,
                    {
                      "y": null
                    }
                  ]
                }
                """)
    }

    @Test func stringsEscapeTheWayPythonDoes() {
        #expect(JSONNode.string("a\"b\\c").serialised() == "\"a\\\"b\\\\c\"")
        #expect(JSONNode.string("\n\t\r").serialised() == "\"\\n\\t\\r\"")
        // A forward slash is left alone, which some JSON writers escape and Python does not.
        #expect(JSONNode.string("/").serialised() == "\"/\"")
    }

    @Test func aControlCharacterWithNoShortFormTakesTheFourDigitEscape() {
        #expect(JSONNode.string("\u{01}").serialised() == "\"\\u0001\"")
        #expect(JSONNode.string("\u{1F}").serialised() == "\"\\u001f\"")
    }

    @Test func nonASCIIIsEscapedBecausePythonDefaultsToEnsureASCII() {
        // A project's file name is the one string here a user can put anything into.
        #expect(JSONNode.string("\u{E9}").serialised() == "\"\\u00e9\"")
    }

    @Test func anAstralCharacterBecomesASurrogatePair() {
        // json.dumps writes the UTF-16 pair for U+1F941, not one six-digit escape.
        #expect(JSONNode.string("\u{1F941}").serialised() == "\"\\ud83e\\udd41\"")
    }
}
