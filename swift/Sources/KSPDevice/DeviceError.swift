import CoreMIDI

/// A failure at the wire, worded so the message names the fix. That wording is the whole value
/// of this layer over an `OSStatus`, so it lives in one place rather than at each throw.
public struct DeviceError: Error, Equatable, CustomStringConvertible {
    public let description: String

    init(_ description: String) {
        self.description = description
    }
}

extension DeviceError {
    /// Nothing published the endpoint at all.
    static func notAttached(_ name: String) -> DeviceError {
        DeviceError(
            "no MIDI device named \"\(name)\" -- is it plugged in over USB and powered on?")
    }

    /// The endpoint is published and takes sends, and the device behind it is mute (spec 7.9.2).
    /// Enumerating it proves nothing, which is why this is reached by an identity exchange.
    static let notAnswering = DeviceError(
        "the KeyStep Pro is not answering -- quit MIDI Control Center, and if that does not "
            + "help, run 'killall MIDIServer'")

    static func noReply(to request: [UInt8], within milliseconds: Int) -> DeviceError {
        DeviceError("no reply to \(hex(request)) within \(milliseconds) ms")
    }

    /// Traffic from something else on the port, or a walk that has lost its place.
    static func manyReplies(to request: [UInt8], _ replies: [[UInt8]]) -> DeviceError {
        DeviceError(
            "\(replies.count) replies to \(hex(request)): "
                + replies.map(hex).joined(separator: ", "))
    }

    static func confused(_ what: String) -> DeviceError {
        DeviceError(what)
    }

    static func coreMIDI(_ what: String, _ status: OSStatus) -> DeviceError {
        DeviceError("\(what) failed: CoreMIDI status \(status)")
    }
}

/// Python's `bytes.hex()`, so a frame reads the same out of either core's diagnostics.
func hex(_ frame: [UInt8]) -> String {
    frame.map { ($0 < 0x10 ? "0" : "") + String($0, radix: 16) }.joined()
}
