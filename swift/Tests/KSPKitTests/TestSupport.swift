import Foundation
import KSPKit
import KSPTape
import KSPTestSupport
import Testing

/// `#expect(a == b)` on 3.5 MB of `Data` renders both sides; an offset is the whole diagnosis.
func firstDifference(_ produced: Data, _ expected: Data) -> String? {
    guard produced != expected else { return nil }

    var offset = 0
    while offset < min(produced.count, expected.count),
        produced[produced.startIndex + offset] == expected[expected.startIndex + offset]
    {
        offset += 1
    }

    func window(_ data: Data) -> String {
        let start = data.index(data.startIndex, offsetBy: max(0, offset - 40))
        let end = data.index(data.startIndex, offsetBy: min(data.count, offset + 40))
        return String(decoding: data[start..<end], as: UTF8.self)
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    return """
        byte \(offset) of \(expected.count) (produced \(produced.count) bytes)
          produced: ...\(window(produced))...
          expected: ...\(window(expected))...
        """
}

/// Requiring the comma to be there keeps a mangled sample from silently becoming the baseline.
func withoutTrailingComma(_ data: Data) -> Data {
    #expect(data.suffix(3) == Data(",\n}".utf8), "sample does not end with MCC's trailing comma")
    return data.dropLast(3) + Data("\n}".utf8)
}

/// Frame 9 of the capture, the device's answer to the identity request.
func identityReply() throws -> [UInt8] {
    let capture = RepoData.root.appending(
        path: "usb_midi_investigation/sysex_until_project_1_track_1_pattern_1.jsonl")
    for line in try String(contentsOf: capture, encoding: .utf8).split(separator: "\n") {
        guard
            let frame = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            frame["frame_number"] as? Int == 9,
            let sysex = frame["sysex_hex"] as? String
        else { continue }
        return try hexBytes(sysex)
    }
    throw KSPError.value("no frame 9 in \(capture.path)")
}
