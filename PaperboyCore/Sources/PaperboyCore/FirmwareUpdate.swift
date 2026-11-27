import CryptoKit
import Foundation

public enum FirmwareTransferResult: Equatable, Sendable {
    case current
    case paused(bytes: Int)
    case committed(previous: String)
}

/// A received rejection proves commit was not accepted, unlike a lost acknowledgement.
public struct FirmwareCommitRejection: Error, Equatable, Sendable, CustomStringConvertible {
    public let status: UInt8
    public var description: String {
        status == 7 ? "Charge the reader to at least 30% or plug it into USB before installing."
            : "The reader declined the firmware commit (status \(status))."
    }
}

/// Uses the existing encrypted, bonded Paperboy link. It never erases the active app slot.
public struct FirmwareUpdateSession: Sendable {
    public static let maximumBytes = 0x640000
    public let transport: any SyncTransport
    public let progress: @Sendable (Double) -> Void

    public init(transport: any SyncTransport, progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.transport = transport
        self.progress = progress
    }

    public func install(_ image: Data, targetVersion: String? = nil,
                        willCommit: @Sendable (String) async throws -> Void = { _ in }) async throws -> String? {
        switch try await transfer(image, targetVersion: targetVersion, willCommit: willCommit) {
        case .current: return nil
        case .committed(let previous): return previous
        case .paused: throw SyncError.protocolViolation("unlimited firmware transfer paused unexpectedly")
        }
    }

    /// A byte budget stages one background window. Only an unlimited window may validate and commit.
    public func transfer(_ image: Data, targetVersion: String? = nil, maximumTransferBytes: Int? = nil,
                         willCommit: @Sendable (String) async throws -> Void = { _ in }) async throws -> FirmwareTransferResult {
        try Task.checkCancellation()
        guard (256...Self.maximumBytes).contains(image.count), image.first == 0xE9 else {
            throw SyncError.dataSource("not an X3 firmware update image")
        }
        let now = UInt32(clamping: Int(Date().timeIntervalSince1970))
        try await transport.send(Frame.hello(version: SyncProtocol.version, unixTime: now).encode(), withResponse: true)
        var previous: String?
        var protocolVersion: UInt8 = 0
        for _ in 0..<64 {
            let bytes = try await transport.receive(timeout: .seconds(15))
            if case .helloAck(let ack) = try? Frame.decode(bytes) {
                guard (1...SyncProtocol.version).contains(ack.version) else { throw SyncError.versionMismatch(device: ack.version) }
                previous = ack.firmwareVersion
                protocolVersion = ack.version
                break
            }
        }
        guard let previous else { throw SyncError.protocolViolation("missing firmware handshake") }
        if previous == targetVersion { return .current }
        let resumable = protocolVersion >= 3
        if !resumable, maximumTransferBytes != nil { return .paused(bytes: 0) }
        var begin = Data([resumable ? 0x45 : 0x40])
        begin.appendLE(UInt32(image.count))
        begin.appendLE(CRC32.checksum(image))
        if resumable { begin.append(contentsOf: SHA256.hash(data: image)) }
        do {
            try Task.checkCancellation()
            try await transport.send(begin, withResponse: true)
            let ready = try await status(resumable ? 0xC5 : 0xC0, timeout: .seconds(30))
            var offset = 0
            if resumable {
                guard ready.count == 10 else { throw SyncError.protocolViolation("invalid firmware resume reply") }
                offset = Int(Self.read32(ready, at: 2))
                guard offset <= image.count else { throw SyncError.protocolViolation("firmware resume offset exceeds image") }
                guard CRC32.checksum(Data(image.prefix(offset))) == Self.read32(ready, at: 6) else {
                    try await transport.send(Data([0x44]), withResponse: true)
                    throw SyncError.dataSource("saved firmware prefix was damaged; staging was reset for the next attempt")
                }
            }
            let chunk = min(511, await transport.maxWriteLength(withResponse: false) - 1)
            guard chunk > 0 else { throw SyncError.transport("Bluetooth frame size is too small") }
            let target = offset + min(image.count - offset, max(0, maximumTransferBytes ?? image.count))
            var sent = offset
            var acknowledged = offset
            progress(Double(offset) / Double(image.count))
            while acknowledged < target {
                try Task.checkCancellation()
                while sent < target && sent - acknowledged < SyncProtocol.flowControlWindow {
                    let end = min(target, sent + chunk, acknowledged + SyncProtocol.flowControlWindow)
                    var frame = Data([0x41])
                    frame.append(image.subdata(in: sent..<end))
                    try await transport.send(frame, withResponse: false)
                    sent = end
                }
                if maximumTransferBytes != nil, sent == target { break }
                let reply = try await transport.receive(timeout: .seconds(20))
                guard reply.first == 0xC1, reply.count == 5 else { throw SyncError.protocolViolation("missing firmware progress") }
                let count = Int(Self.read32(reply, at: 1))
                guard count > acknowledged, count <= sent else { throw SyncError.protocolViolation("invalid firmware progress") }
                acknowledged = count
                progress(Double(count) / Double(image.count))
            }
            if maximumTransferBytes != nil {
                try Task.checkCancellation()
                try await transport.send(Data([0x46]), withResponse: true)
                let paused = try await status(0xC6, timeout: .seconds(10))
                let saved = Int(Self.read32(paused, at: 2))
                guard saved >= offset, saved <= sent, CRC32.checksum(Data(image.prefix(saved))) == Self.read32(paused, at: 6) else {
                    try await transport.send(Data([0x44]), withResponse: true)
                    throw SyncError.dataSource("firmware checkpoint did not match the sent prefix; staging was reset")
                }
                progress(Double(saved) / Double(image.count))
                return .paused(bytes: saved)
            }
            try await transport.send(Data([0x42]), withResponse: true)
            try await status(0xC2, timeout: .seconds(120))
            try Task.checkCancellation()
            try await willCommit(previous)
            try await transport.send(Data([0x43]), withResponse: true)
            try await status(0xC3, timeout: .seconds(15))
            // Accepted is not success: the caller must reconnect and verify the target version.
            return .committed(previous: previous)
        } catch {
            if resumable {
                // Cleanup must also run when the caller's task has been cancelled.
                await Task {
                    do {
                        try await transport.send(Data([0x46]), withResponse: true)
                        try await status(0xC6, timeout: .seconds(3))
                    } catch { /* Disconnect/timeout also closes the saved staging file on the reader. */ }
                }.value
            } else {
                try? await transport.send(Data([0x44]), withResponse: true)
            }
            throw error
        }
    }

    @discardableResult
    private func status(_ type: UInt8, timeout: Duration) async throws -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var reply = Data()
        for _ in 0..<64 {
            let remaining = deadline - clock.now
            guard remaining > .zero else { throw SyncError.timeout("firmware status") }
            reply = try await transport.receive(timeout: remaining)
            if reply.first == 0xC1 { continue }
            break
        }
        guard reply.count == (type == 0xC5 || type == 0xC6 ? 10 : 2), reply.first == type else { throw SyncError.protocolViolation("unexpected firmware reply") }
        guard reply[1] == 0 else {
            if type == 0xC3 { throw FirmwareCommitRejection(status: reply[1]) }
            let detail: String
            switch reply[1] {
            case 7: detail = "charge the reader to at least 30% or plug it into USB"
            case 8: detail = "the reader rejected the firmware image or its board type"
            default: detail = "firmware update rejected: \(SyncStatus(rawValue: reply[1]))"
            }
            throw SyncError.transport(detail)
        }
        return reply
    }

    private static func read32(_ bytes: Data, at: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * $1) }
    }
}
