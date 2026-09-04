import Foundation
import KSPKit

/// The device as `BulkRead` wants it, over any port that carries whole SysEx frames.
public final class DeviceTransport: Transport {
    /// `ksp_cli.usb_transport.DEFAULT_TIMEOUT_MS`: long enough for the device to answer, short
    /// enough that a mute one is a failure rather than a hang.
    public static let defaultTimeoutMs = 1000

    private let port: any SysExPort
    private let timeoutMs: Int

    /// Every request that went on the wire, the sentinel re-reads included.
    public private(set) var exchanges = 0

    /// Values recovered from CoreMIDI's truncation. Nothing else reports it: the frame is
    /// well-formed and the address echoes, so a silent loss looks exactly like a short read.
    public private(set) var repairs = 0

    public init(port: any SysExPort, timeoutMs: Int = defaultTimeoutMs) {
        self.port = port
        self.timeoutMs = timeoutMs
    }

    /// The firmware version, which no read address carries -- and the only proof the device is
    /// alive, because a published endpoint outlives its ability to answer (spec 7.9.2).
    public func identify() throws -> String {
        guard let reply = try awaitReply(to: Sysex.identityRequest) else {
            throw DeviceError.notAnswering
        }
        do {
            return try Sysex.parseIdentity(reply)
        } catch {
            // A `KSPError` rather than a `DeviceError`, as Python raises `ValueError` here and
            // not `TransportError`: a frame that came back and answered the wrong question is
            // what the caller prefixes with the slot it was reading.
            throw KSPError.value("\(error): \(hex(reply))")
        }
    }

    public func send(_ frame: [UInt8]) throws {
        try port.send(frame)
    }

    public func exchange(_ request: [UInt8]) throws -> [UInt8] {
        guard let reply = try awaitReply(to: request) else {
            throw DeviceError.timedOut(after: timeoutMs)
        }
        guard let carried = Sentinel.shortfall(of: reply, to: request) else { return reply }

        let repaired = try Sentinel.repair(request, reply, carried: carried) { tail in
            guard let answer = try awaitReply(to: tail) else {
                throw DeviceError.timedOut(after: timeoutMs)
            }
            return answer
        }
        repairs += repaired.repairs
        return repaired.frame
    }

    /// One transaction: the request, then frames until the ack closes it (spec 7.1).
    /// nil is total silence; a transaction that closed without answering throws instead.
    private func awaitReply(to request: [UInt8]) throws -> [UInt8]? {
        port.drain()
        exchanges += 1
        try port.send(request)

        // The identity request is universal and its reply is not acked -- measured on hardware,
        // unlike every Arturia frame -- so for that one frame the reply itself ends the exchange.
        let acked = request.starts(with: Sysex.header)
        var replies: [[UInt8]] = []
        var heard = false
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while let frame = port.nextFrame(within: max(0, deadline.timeIntervalSinceNow)) {
            heard = true
            if frame == Sysex.ack { break }
            replies.append(frame)
            if !acked { break }
        }
        guard replies.count <= 1 else { throw DeviceError.manyReplies(to: request, replies) }
        guard let reply = replies.first else {
            // Python keeps these apart: an ack alone is a transaction that answered nothing,
            // while hearing nothing at all is the timeout.
            if heard { throw DeviceError.noReply(to: request) }
            return nil
        }
        return reply
    }
}
