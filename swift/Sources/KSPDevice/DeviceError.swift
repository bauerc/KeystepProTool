import CoreMIDI

/// A failure at the wire. The wording lives here rather than at each throw, because naming the
/// fix is the whole value of this layer over an `OSStatus`.
public struct DeviceError: Error, Equatable, CustomStringConvertible {
    public let description: String

    init(_ description: String) {
        self.description = description
    }
}

extension DeviceError {
    static func notAttached(_ name: String) -> DeviceError {
        DeviceError(
            "no MIDI device named \"\(name)\" -- is it plugged in over USB and powered on?")
    }

    /// The endpoint is published and takes sends, and the device behind it is mute (spec 7.9.2).
    /// Enumerating it proves nothing, which is why an identity exchange is what reaches this.
    static let notAnswering = DeviceError(
        "the KeyStep Pro is not answering -- quit MIDI Control Center, and if that does not "
            + "help, run 'killall MIDIServer'")

    /// Python's two silences, kept apart as `usb_transport` keeps them: nothing came back at all.
    static func timedOut(after milliseconds: Int) -> DeviceError {
        DeviceError("timed out after \(milliseconds) ms waiting for a reply")
    }

    /// The transaction closed, and nothing in it answered the question.
    static func noReply(to request: [UInt8]) -> DeviceError {
        DeviceError("no reply to \(hex(request))")
    }

    /// Traffic from something else on the port, or a walk that has lost its place.
    static func manyReplies(to request: [UInt8], _ replies: [[UInt8]]) -> DeviceError {
        DeviceError(
            "\(replies.count) replies to \(hex(request)): "
                + replies.map(hex).joined(separator: ", "))
    }

    static func oversizedFrame(_ bytes: Int, capacity: Int) -> DeviceError {
        DeviceError("\(bytes) bytes is more than the \(capacity) one MIDI packet carries")
    }

    static func unreadableIdentity(_ reply: [UInt8], _ reason: any Error) -> DeviceError {
        DeviceError("\(reason): \(hex(reply))")
    }

    /// A re-read addressed past what a seven-bit SysEx byte can carry.
    static func unaddressable(index: Int, count: Int) -> DeviceError {
        DeviceError("re-reading \(count) values from index \(index) needs more than a SysEx byte")
    }

    static func coreMIDI(_ what: String, _ status: OSStatus) -> DeviceError {
        DeviceError("\(what) failed: CoreMIDI status \(status)")
    }
}

/// Python's `bytes.hex()`, so a frame reads the same out of either core's diagnostics.
func hex(_ frame: [UInt8]) -> String {
    frame.map { ($0 < 0x10 ? "0" : "") + String($0, radix: 16) }.joined()
}
