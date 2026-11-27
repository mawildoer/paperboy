import Foundation

/// Paperboy Bluetooth protocol, version 3. See docs/bluetooth-protocol.md.
///
/// Each GATT write (phone → device, RX characteristic) or notification (device → phone, TX
/// characteristic) carries exactly one frame: one type byte followed by the payload.
/// All integers are little-endian.
public enum SyncProtocol {
    public static let version: UInt8 = 3

    public static let serviceUUID = "8E400001-7B2A-4B1F-9C5D-5A1EF0C0DE01"
    /// Phone → device. Write and write-without-response, encrypted.
    public static let rxCharacteristicUUID = "8E400002-7B2A-4B1F-9C5D-5A1EF0C0DE01"
    /// Device → phone. Notify, encrypted.
    public static let txCharacteristicUUID = "8E400003-7B2A-4B1F-9C5D-5A1EF0C0DE01"

    /// The phone never sends more than this many bytes past the last PUT_PROGRESS value.
    public static let flowControlWindow = 8192
    /// The device reports progress each time this many more bytes are on the card.
    public static let progressInterval = 4096
    /// Longest value of a length-prefixed string field (the length is one byte).
    public static let maxStringBytes = 255
    /// PUT_BEGIN without its three strings: type, id, size, crc, time, three length bytes.
    public static let putBeginFixedBytes = 1 + ArticleID.byteCount + 4 + 4 + 4 + 3
}

public enum FrameType: UInt8, Sendable, CaseIterable {
    // Phone → device
    case hello = 0x01
    case list = 0x02
    case putBegin = 0x10
    case putData = 0x11
    case putEnd = 0x12
    case touch = 0x21
    case delete = 0x20
    case bye = 0x30
    // Device → phone
    case helloAck = 0x81
    case listItems = 0x82
    case listEnd = 0x83
    case putReady = 0x90
    case putProgress = 0x91
    case putResult = 0x92
    case touchResult = 0xA1
    case deleteResult = 0xA0
}

/// Status byte of PUT_READY, PUT_RESULT and DELETE_RESULT.
public struct SyncStatus: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let ok = SyncStatus(rawValue: 0)
    public static let busy = SyncStatus(rawValue: 1)
    public static let noSpace = SyncStatus(rawValue: 2)
    public static let storageError = SyncStatus(rawValue: 3)
    public static let checksumMismatch = SyncStatus(rawValue: 4)
    public static let badRequest = SyncStatus(rawValue: 5)
    public static let exists = SyncStatus(rawValue: 6)

    public var description: String {
        switch rawValue {
        case 0: return "ok"
        case 1: return "busy"
        case 2: return "no space"
        case 3: return "storage error"
        case 4: return "checksum mismatch"
        case 5: return "bad request"
        case 6: return "exists"
        default: return "unknown status \(rawValue)"
        }
    }
}

public struct PutBegin: Equatable, Sendable {
    public var id: ArticleID
    /// Size of the whole file in bytes.
    public var size: UInt32
    /// CRC-32 (zlib) of the whole file.
    public var crc32: UInt32
    /// Publication time in Unix seconds, used by the reader's Published view.
    public var time: UInt32
    public var source: String
    public var title: String
    public var author: String

    public init(id: ArticleID, size: UInt32, crc32: UInt32, time: UInt32, source: String, title: String, author: String) {
        self.id = id
        self.size = size
        self.crc32 = crc32
        self.time = time
        self.source = source
        self.title = title
        self.author = author
    }
}

public struct HelloAck: Equatable, Sendable {
    public var version: UInt8
    public var batteryPercent: UInt8
    public var freeSpaceMB: UInt32
    /// The rest of the frame, UTF-8, no length prefix and no terminator.
    public var firmwareVersion: String

    public init(version: UInt8, batteryPercent: UInt8, freeSpaceMB: UInt32, firmwareVersion: String) {
        self.version = version
        self.batteryPercent = batteryPercent
        self.freeSpaceMB = freeSpaceMB
        self.firmwareVersion = firmwareVersion
    }
}

public struct ListItem: Equatable, Hashable, Sendable {
    public static let encodedSize = ArticleID.byteCount + 1
    public var id: ArticleID
    /// Bit 0 = read. Other bits are reserved and preserved.
    public var flags: UInt8

    public init(id: ArticleID, flags: UInt8) {
        self.id = id
        self.flags = flags
    }

    public init(id: ArticleID, read: Bool) {
        self.id = id
        self.flags = read ? 1 : 0
    }

    public var isRead: Bool { flags & 0x01 != 0 }
}

public enum FrameError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    case unknownType(UInt8)
    case badLength(type: FrameType, length: Int)
    case stringTooLong(field: String, bytes: Int)
    case invalidUTF8(field: String)

    public var description: String {
        switch self {
        case .empty: return "empty frame"
        case .unknownType(let t): return "unknown frame type 0x" + String(t, radix: 16)
        case .badLength(let type, let length): return "bad length \(length) for \(type) frame"
        case .stringTooLong(let field, let bytes): return "\(field) is \(bytes) bytes, the limit is 255"
        case .invalidUTF8(let field): return "\(field) is not valid UTF-8"
        }
    }
}

public enum Frame: Equatable, Sendable {
    case hello(version: UInt8, unixTime: UInt32)
    case list
    case putBegin(PutBegin)
    case putData(Data)
    case putEnd
    case touch(SyncTouch)
    case touchResult(SyncStatus)
    case delete(ArticleID)
    case bye
    case helloAck(HelloAck)
    case listItems([ListItem])
    case listEnd(total: UInt16)
    case putReady(SyncStatus)
    case putProgress(UInt32)
    case putResult(SyncStatus)
    case deleteResult(SyncStatus)

    public var type: FrameType {
        switch self {
        case .hello: return .hello
        case .list: return .list
        case .putBegin: return .putBegin
        case .putData: return .putData
        case .putEnd: return .putEnd
        case .touch: return .touch
        case .touchResult: return .touchResult
        case .delete: return .delete
        case .bye: return .bye
        case .helloAck: return .helloAck
        case .listItems: return .listItems
        case .listEnd: return .listEnd
        case .putReady: return .putReady
        case .putProgress: return .putProgress
        case .putResult: return .putResult
        case .deleteResult: return .deleteResult
        }
    }

    // MARK: Encoding

    public func encode() throws -> Data {
        var out = Data([type.rawValue])
        switch self {
        case .hello(let version, let unixTime):
            out.append(version)
            out.appendLE(unixTime)
        case .list, .putEnd, .bye:
            break
        case .putBegin(let p):
            out.append(contentsOf: p.id.bytes)
            out.appendLE(p.size)
            out.appendLE(p.crc32)
            out.appendLE(p.time)
            try out.appendShortString(p.source, field: "source")
            try out.appendShortString(p.title, field: "title")
            try out.appendShortString(p.author, field: "author")
        case .putData(let bytes):
            out.append(bytes)
        case .touch(let touch):
            out.append(contentsOf: touch.id.bytes)
            out.appendLE(touch.nonce)
        case .touchResult(let status):
            out.append(status.rawValue)
        case .delete(let id):
            out.append(contentsOf: id.bytes)
        case .helloAck(let ack):
            out.append(ack.version)
            out.append(ack.batteryPercent)
            out.appendLE(ack.freeSpaceMB)
            out.append(contentsOf: Array(ack.firmwareVersion.utf8))
        case .listItems(let items):
            for item in items {
                out.append(contentsOf: item.id.bytes)
                out.append(item.flags)
            }
        case .listEnd(let total):
            out.appendLE(total)
        case .putReady(let status), .putResult(let status), .deleteResult(let status):
            out.append(status.rawValue)
        case .putProgress(let stored):
            out.appendLE(stored)
        }
        return out
    }

    // MARK: Decoding

    /// Decode one frame. Fixed-size frames must have exactly the documented length.
    public static func decode(_ data: Data) throws -> Frame {
        let bytes = [UInt8](data)
        guard let first = bytes.first else { throw FrameError.empty }
        guard let type = FrameType(rawValue: first) else { throw FrameError.unknownType(first) }
        var reader = ByteReader(bytes: bytes, offset: 1)
        let payloadLength = bytes.count - 1
        func fail() -> FrameError { .badLength(type: type, length: bytes.count) }
        func requireLength(_ n: Int) throws {
            if payloadLength != n { throw fail() }
        }

        switch type {
        case .hello:
            try requireLength(5)
            guard let version = reader.u8(), let time = reader.u32() else { throw fail() }
            return .hello(version: version, unixTime: time)
        case .list:
            try requireLength(0)
            return .list
        case .putBegin:
            guard let idBytes = reader.take(ArticleID.byteCount), let id = ArticleID(bytes: idBytes),
                  let size = reader.u32(), let crc = reader.u32(), let time = reader.u32()
            else { throw fail() }
            guard let source = reader.shortStringBytes(), let title = reader.shortStringBytes(),
                  let author = reader.shortStringBytes(), reader.isAtEnd
            else { throw fail() }
            guard let sourceText = String(validatingUTF8Bytes: source) else { throw FrameError.invalidUTF8(field: "source") }
            guard let titleText = String(validatingUTF8Bytes: title) else { throw FrameError.invalidUTF8(field: "title") }
            guard let authorText = String(validatingUTF8Bytes: author) else { throw FrameError.invalidUTF8(field: "author") }
            return .putBegin(PutBegin(id: id, size: size, crc32: crc, time: time, source: sourceText, title: titleText, author: authorText))
        case .putData:
            return .putData(Data(bytes.dropFirst()))
        case .putEnd:
            try requireLength(0)
            return .putEnd
        case .touch:
            try requireLength(12)
            guard let bytes = reader.take(ArticleID.byteCount), let id = ArticleID(bytes: bytes), let nonce = reader.u32() else { throw fail() }
            return .touch(SyncTouch(id: id, nonce: nonce))
        case .touchResult:
            try requireLength(1)
            guard let status = reader.u8() else { throw fail() }
            return .touchResult(SyncStatus(rawValue: status))
        case .delete:
            try requireLength(ArticleID.byteCount)
            guard let idBytes = reader.take(ArticleID.byteCount), let id = ArticleID(bytes: idBytes) else { throw fail() }
            return .delete(id)
        case .bye:
            try requireLength(0)
            return .bye
        case .helloAck:
            guard payloadLength >= 6, let version = reader.u8(), let battery = reader.u8(), let free = reader.u32() else {
                throw fail()
            }
            // Lossy on purpose: a firmware version string must never break a sync.
            let firmware = String(decoding: reader.rest(), as: UTF8.self)
            return .helloAck(HelloAck(version: version, batteryPercent: battery, freeSpaceMB: free, firmwareVersion: firmware))
        case .listItems:
            guard payloadLength % ListItem.encodedSize == 0 else { throw fail() }
            var items: [ListItem] = []
            items.reserveCapacity(payloadLength / ListItem.encodedSize)
            while !reader.isAtEnd {
                guard let idBytes = reader.take(ArticleID.byteCount), let id = ArticleID(bytes: idBytes), let flags = reader.u8() else {
                    throw fail()
                }
                items.append(ListItem(id: id, flags: flags))
            }
            return .listItems(items)
        case .listEnd:
            try requireLength(2)
            guard let total = reader.u16() else { throw fail() }
            return .listEnd(total: total)
        case .putReady:
            try requireLength(1)
            guard let status = reader.u8() else { throw fail() }
            return .putReady(SyncStatus(rawValue: status))
        case .putProgress:
            try requireLength(4)
            guard let stored = reader.u32() else { throw fail() }
            return .putProgress(stored)
        case .putResult:
            try requireLength(1)
            guard let status = reader.u8() else { throw fail() }
            return .putResult(SyncStatus(rawValue: status))
        case .deleteResult:
            try requireLength(1)
            guard let status = reader.u8() else { throw fail() }
            return .deleteResult(SyncStatus(rawValue: status))
        }
    }

    /// A one-line description for logs. Never includes article bytes.
    public var logDescription: String {
        switch self {
        case .hello(let version, let unixTime): return "HELLO v\(version) time=\(unixTime)"
        case .list: return "LIST"
        case .putBegin(let p):
            return "PUT_BEGIN id=\(p.id) size=\(p.size) crc=\(String(format: "%08x", p.crc32)) time=\(p.time) source=\"\(p.source)\" title=\"\(p.title)\" author=\"\(p.author)\""
        case .putData(let d): return "PUT_DATA \(d.count) bytes"
        case .putEnd: return "PUT_END"
        case .touch(let touch): return "TOUCH id=\(touch.id) nonce=\(touch.nonce)"
        case .touchResult(let status): return "TOUCH_RESULT \(status)"
        case .delete(let id): return "DELETE id=\(id)"
        case .bye: return "BYE"
        case .helloAck(let a):
            return "HELLO_ACK v\(a.version) battery=\(a.batteryPercent)% free=\(a.freeSpaceMB)MB fw=\"\(a.firmwareVersion)\""
        case .listItems(let items): return "LIST_ITEMS \(items.count) item(s)"
        case .listEnd(let total): return "LIST_END total=\(total)"
        case .putReady(let s): return "PUT_READY \(s)"
        case .putProgress(let n): return "PUT_PROGRESS \(n)"
        case .putResult(let s): return "PUT_RESULT \(s)"
        case .deleteResult(let s): return "DELETE_RESULT \(s)"
        }
    }
}

// MARK: - Text helpers for the length-prefixed strings

public enum SyncText {
    /// Cut a string to at most `maxBytes` of UTF-8 without splitting a character.
    public static func truncate(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        if text.utf8.count <= maxBytes { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > maxBytes { break }
            result.append(character)
            used += size
        }
        return result
    }

    /// The device stores source/title/author in a tab-separated file, one line per article,
    /// so tabs, newlines and other control characters are replaced by spaces.
    public static func sanitizeField(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            let isBreak = scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x2028 || scalar.value == 0x2029
                || scalar == " "
            if isBreak {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(scalar)
                lastWasSpace = false
            }
        }
        var result = String(out)
        while result.hasSuffix(" ") { result.removeLast() }
        return result
    }
}

// MARK: - Byte helpers

extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    fileprivate mutating func appendShortString(_ text: String, field: String) throws {
        let utf8 = Array(text.utf8)
        guard utf8.count <= SyncProtocol.maxStringBytes else {
            throw FrameError.stringTooLong(field: field, bytes: utf8.count)
        }
        append(UInt8(utf8.count))
        append(contentsOf: utf8)
    }
}

extension String {
    /// Strict UTF-8 decoding: nil when the bytes are not valid UTF-8.
    init?(validatingUTF8Bytes bytes: [UInt8]) {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        self = text
    }
}

struct ByteReader {
    let bytes: [UInt8]
    var offset: Int

    init(bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var isAtEnd: Bool { offset >= bytes.count }
    var remaining: Int { max(0, bytes.count - offset) }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(bytes[offset + i]) << UInt32(8 * i) }
        return value
    }

    mutating func take(_ count: Int) -> [UInt8]? {
        guard count >= 0, remaining >= count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, remaining >= count else { return false }
        offset += count
        return true
    }

    mutating func shortStringBytes() -> [UInt8]? {
        guard let length = u8() else { return nil }
        return take(Int(length))
    }

    mutating func rest() -> [UInt8] {
        defer { offset = bytes.count }
        return Array(bytes[min(offset, bytes.count)...])
    }
}
