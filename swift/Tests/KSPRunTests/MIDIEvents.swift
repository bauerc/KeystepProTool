import Foundation
import KSPKit

/// A Standard MIDI file as `tools/midi_events.py` prints it, read here rather than by
/// `swift-midi-file`, which wrote the file under test. Types it has never seen are refused.
func midiEvents(_ data: Data) throws -> [String] {
    var file = ByteReader(bytes: [UInt8](data))
    guard try file.take(4).elementsEqual("MThd".utf8) else {
        throw KSPError.value("no MThd header")
    }
    let headerLength = try file.integer(4)
    let format = try file.integer(2)
    _ = try file.integer(2)
    let ticksPerBeat = try file.integer(2)
    _ = try file.take(headerLength - 6)

    var tracks: [[String]] = []
    while !file.atEnd {
        guard try file.take(4).elementsEqual("MTrk".utf8) else {
            throw KSPError.value("no MTrk header at the start of track \(tracks.count)")
        }
        var track = ByteReader(bytes: Array(try file.take(file.integer(4))))
        tracks.append(try events(&track))
    }

    var lines = ["format \(format) ticks_per_beat \(ticksPerBeat) tracks \(tracks.count)"]
    for (index, track) in tracks.enumerated() {
        lines.append("track \(index)")
        lines += track
    }
    return lines
}

/// `repr()` of a Python `str`, over the characters mido's Latin-1 decoding can produce.
func pythonRepr(_ text: String) -> String {
    let quote: Unicode.Scalar = text.contains("'") && !text.contains("\"") ? "\"" : "'"
    var repr = String(quote)
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\\": repr += "\\\\"
        case "\n": repr += "\\n"
        case "\r": repr += "\\r"
        case "\t": repr += "\\t"
        case quote: repr += "\\\(quote)"
        case "\u{00}"..."\u{1F}", "\u{7F}"..."\u{A0}", "\u{AD}":
            repr += String(format: "\\x%02x", scalar.value)
        default: repr.unicodeScalars.append(scalar)
        }
    }
    return repr + String(quote)
}

private typealias Event = (type: String, fields: [(name: String, value: String)])

private func events(_ track: inout ByteReader) throws -> [String] {
    var lines: [String] = []
    var tick = 0
    var running: UInt8?
    while !track.atEnd {
        tick += try track.variableLength()
        var status = try track.byte()
        var first: UInt8?
        if status < 0x80 {
            guard let running else { throw KSPError.value("running status with none set") }
            first = status
            status = running
        }

        let event: Event
        switch status {
        case 0xFF: event = try meta(&track)
        case 0xF0, 0xF7:
            _ = try track.take(track.variableLength())
            event = ("sysex", [])
        default:
            running = status
            event = try channelMessage(status, first: first, &track)
        }

        let fields = event.fields.map { "\($0.name)=\($0.value)" }.joined(separator: " ")
        let spelled = String(tick)
        let padded = String(repeating: " ", count: max(0, 8 - spelled.count)) + spelled
        var line = "  \(padded) \(event.type) \(fields)"
        while line.last == " " { line.removeLast() }
        lines.append(line)
    }
    return lines
}

private func channelMessage(_ status: UInt8, first: UInt8?, _ track: inout ByteReader) throws
    -> Event
{
    func data() throws -> String { String(try track.byte()) }
    let channel = ("channel", String(status & 0x0F))
    let firstByte = try first.map { String($0) } ?? data()
    switch status & 0xF0 {
    case 0x80: return ("note_off", [channel, ("note", firstByte), ("velocity", try data())])
    case 0x90: return ("note_on", [channel, ("note", firstByte), ("velocity", try data())])
    case 0xA0: return ("polytouch", [channel, ("note", firstByte), ("value", try data())])
    case 0xB0: return ("control_change", [channel, ("control", firstByte), ("value", try data())])
    case 0xC0: return ("program_change", [channel, ("program", firstByte)])
    case 0xD0: return ("aftertouch", [channel, ("value", firstByte)])
    case 0xE0:
        _ = try data()
        return ("pitchwheel", [channel])
    default:
        throw KSPError.value(String(format: "status 0x%02X has no canonical form here", status))
    }
}

private func meta(_ track: inout ByteReader) throws -> Event {
    let kind = try track.byte()
    let data = Array(try track.take(track.variableLength()))
    let text = pythonRepr(String(String.UnicodeScalarView(data.map { Unicode.Scalar($0) })))
    switch kind {
    case 0x01: return ("text", [("text", text)])
    case 0x02: return ("copyright", [("text", text)])
    case 0x03: return ("track_name", [("name", text)])
    case 0x04: return ("instrument_name", [("name", text)])
    case 0x05: return ("lyrics", [("text", text)])
    case 0x06: return ("marker", [("text", text)])
    case 0x07: return ("cue_marker", [("text", text)])
    case 0x2F: return ("end_of_track", [])
    case 0x51 where data.count == 3:
        let tempo = data.reduce(0) { $0 << 8 | Int($1) }
        return ("set_tempo", [("tempo", String(tempo))])
    case 0x58 where data.count == 4:
        return (
            "time_signature",
            [
                ("numerator", String(data[0])), ("denominator", String(1 << data[1])),
                ("clocks_per_click", String(data[2])),
                ("notated_32nd_notes_per_beat", String(data[3])),
            ]
        )
    default: throw KSPError.value(String(format: "meta 0x%02X has no canonical form here", kind))
    }
}

private struct ByteReader {
    let bytes: [UInt8]
    var offset = 0

    var atEnd: Bool { offset >= bytes.count }

    mutating func byte() throws -> UInt8 { try take(1)[offset - 1] }

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, offset + count <= bytes.count else {
            throw KSPError.value("the file ends inside a chunk")
        }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    mutating func integer(_ width: Int) throws -> Int {
        try take(width).reduce(0) { $0 << 8 | Int($1) }
    }

    mutating func variableLength() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            let next = try byte()
            value = value << 7 | Int(next & 0x7F)
            if next < 0x80 { return value }
        }
        throw KSPError.value("a variable-length quantity runs past four bytes")
    }
}
