import Foundation

/// Uses the existing encrypted, bonded Paperboy link. It never erases the active app slot.
public struct FirmwareUpdateSession: Sendable {
    public static let maximumBytes = 0x640000
    public let transport: any SyncTransport
    public let progress: @Sendable (Double) -> Void

    public init(transport: any SyncTransport, progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.transport = transport
        self.progress = progress
    }

    public func install(_ image: Data, targetVersion: String? = nil) async throws -> String? {
        guard (256...Self.maximumBytes).contains(image.count), image.first == 0xE9 else {
            throw SyncError.dataSource("not an X3 firmware update image")
        }
        let now = UInt32(clamping: Int(Date().timeIntervalSince1970))
        try await transport.send(Frame.hello(version: SyncProtocol.version, unixTime: now).encode(), withResponse: true)
        var previous: String?
        for _ in 0..<64 {
            let bytes = try await transport.receive(timeout: .seconds(15))
            if case .helloAck(let ack) = try? Frame.decode(bytes) {
                guard ack.version == SyncProtocol.version || ack.version == 1 else { throw SyncError.versionMismatch(device: ack.version) }
                previous = ack.firmwareVersion
                break
            }
        }
        guard let previous else { throw SyncError.protocolViolation("missing firmware handshake") }
        if previous == targetVersion { return nil }
        var begin = Data([0x40])
        begin.appendLE(UInt32(image.count))
        begin.appendLE(CRC32.checksum(image))
        do {
            try await transport.send(begin, withResponse: true)
            try await status(0xC0, timeout: .seconds(15))
            let chunk = min(511, await transport.maxWriteLength(withResponse: false) - 1)
            guard chunk > 0 else { throw SyncError.transport("Bluetooth frame size is too small") }
            var sent = 0
            var acknowledged = 0
            while acknowledged < image.count {
                try Task.checkCancellation()
                while sent < image.count && sent - acknowledged < SyncProtocol.flowControlWindow {
                    let end = min(image.count, sent + chunk, acknowledged + SyncProtocol.flowControlWindow)
                    var frame = Data([0x41])
                    frame.append(image.subdata(in: sent..<end))
                    try await transport.send(frame, withResponse: false)
                    sent = end
                }
                let reply = try await transport.receive(timeout: .seconds(20))
                guard reply.first == 0xC1, reply.count == 5 else { throw SyncError.protocolViolation("missing firmware progress") }
                let count = Int(Self.read32(reply, at: 1))
                guard count > acknowledged, count <= sent else { throw SyncError.protocolViolation("invalid firmware progress") }
                acknowledged = count
                progress(Double(count) / Double(image.count))
            }
            try await transport.send(Data([0x42]), withResponse: true)
            try await status(0xC2, timeout: .seconds(60))
            try await transport.send(Data([0x43]), withResponse: true)
            try await status(0xC3, timeout: .seconds(15))
            // Accepted is not success: the caller must reconnect and verify the target version.
            return previous
        } catch {
            try? await transport.send(Data([0x44]), withResponse: true) // abandon only the staged image
            throw error
        }
    }

    private func status(_ type: UInt8, timeout: Duration) async throws {
        let reply = try await transport.receive(timeout: timeout)
        guard reply.count == 2, reply.first == type else { throw SyncError.protocolViolation("unexpected firmware reply") }
        guard reply[1] == 0 else {
            let detail: String
            switch reply[1] {
            case 7: detail = "charge the reader to at least 30% or plug it into USB"
            case 8: detail = "the reader rejected the firmware image or its board type"
            default: detail = "firmware update rejected: \(SyncStatus(rawValue: reply[1]))"
            }
            throw SyncError.transport(detail)
        }
    }

    private static func read32(_ bytes: Data, at: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * $1) }
    }
}
