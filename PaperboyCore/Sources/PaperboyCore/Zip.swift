import Compression
import Foundation

/// Minimal ZIP writer: every entry is stored (method 0), no data descriptors, no ZIP64.
/// That is all an EPUB needs, and it keeps the device's work to a plain copy.
public struct ZipWriter {
    private struct Entry {
        let name: [UInt8]
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    public enum ZipWriteError: Error, Sendable {
        case tooLarge
        case badName(String)
    }

    private var data = Data()
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    /// `modified` stamps every entry; pass a fixed date for reproducible output.
    public init(modified: Date = Date(timeIntervalSince1970: 0)) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: modified)
        let year = min(max((c.year ?? 1980), 1980), 2107)
        dosDate = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        dosTime = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
    }

    public mutating func add(name: String, contents: Data) throws {
        let nameBytes = Array(name.utf8)
        guard !nameBytes.isEmpty, nameBytes.count <= 0xFFFF, nameBytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else {
            throw ZipWriteError.badName(name)
        }
        guard contents.count <= Int(Int32.max), data.count <= Int(Int32.max), entries.count < 0xFFFF else {
            throw ZipWriteError.tooLarge
        }
        let crc = CRC32.checksum(contents)
        let entry = Entry(name: nameBytes, crc: crc, size: UInt32(contents.count), offset: UInt32(data.count))
        data.appendLE(0x0403_4B50 as UInt32)  // local file header
        data.appendLE(10 as UInt16)  // version needed: 1.0 (stored)
        data.appendLE(0 as UInt16)  // flags
        data.appendLE(0 as UInt16)  // method: stored
        data.appendLE(dosTime)
        data.appendLE(dosDate)
        data.appendLE(crc)
        data.appendLE(entry.size)  // compressed size
        data.appendLE(entry.size)  // uncompressed size
        data.appendLE(UInt16(nameBytes.count))
        data.appendLE(0 as UInt16)  // extra field length (must be 0 for the EPUB mimetype entry)
        data.append(contentsOf: nameBytes)
        data.append(contents)
        entries.append(entry)
    }

    public func finish() throws -> Data {
        var out = data
        let directoryOffset = out.count
        for entry in entries {
            out.appendLE(0x0201_4B50 as UInt32)  // central directory header
            out.appendLE(20 as UInt16)  // version made by
            out.appendLE(10 as UInt16)  // version needed
            out.appendLE(0 as UInt16)  // flags
            out.appendLE(0 as UInt16)  // method
            out.appendLE(dosTime)
            out.appendLE(dosDate)
            out.appendLE(entry.crc)
            out.appendLE(entry.size)
            out.appendLE(entry.size)
            out.appendLE(UInt16(entry.name.count))
            out.appendLE(0 as UInt16)  // extra length
            out.appendLE(0 as UInt16)  // comment length
            out.appendLE(0 as UInt16)  // disk number
            out.appendLE(0 as UInt16)  // internal attributes
            out.appendLE(0 as UInt32)  // external attributes
            out.appendLE(entry.offset)
            out.append(contentsOf: entry.name)
        }
        let directorySize = out.count - directoryOffset
        guard out.count <= Int(Int32.max) else { throw ZipWriteError.tooLarge }
        out.appendLE(0x0605_4B50 as UInt32)  // end of central directory
        out.appendLE(0 as UInt16)
        out.appendLE(0 as UInt16)
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt32(directorySize))
        out.appendLE(UInt32(directoryOffset))
        out.appendLE(0 as UInt16)  // comment length
        return out
    }
}

/// Minimal ZIP reader (stored and deflated entries, no ZIP64, no encryption). Used by the tests
/// to re-read what `ZipWriter` wrote and by the CLI to read metadata out of existing EPUBs.
public struct ZipReader: Sendable {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let method: UInt16
        public let crc32: UInt32
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let localHeaderOffset: Int
    }

    public enum ZipReadError: Error, Sendable, Equatable {
        case notAZip
        case truncated
        case unsupported(String)
        case crcMismatch(String)
        case noSuchEntry(String)
    }

    public let entries: [Entry]
    private let bytes: [UInt8]

    public init(_ data: Data) throws {
        let bytes = [UInt8](data)
        self.bytes = bytes
        guard bytes.count >= 22 else { throw ZipReadError.notAZip }
        // Find the end-of-central-directory record, scanning back over a possible comment.
        var eocd = -1
        var i = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        while i >= lowest {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipReadError.notAZip }
        var reader = ByteReader(bytes: bytes, offset: eocd + 4)
        guard reader.skip(6), let count = reader.u16(), reader.skip(4), let directoryOffset = reader.u32() else {
            throw ZipReadError.truncated
        }
        var entries: [Entry] = []
        var directory = ByteReader(bytes: bytes, offset: Int(directoryOffset))
        for _ in 0..<count {
            guard let signature = directory.u32(), signature == 0x0201_4B50 else { throw ZipReadError.truncated }
            guard directory.skip(4), let flags = directory.u16(), let method = directory.u16(), directory.skip(4),
                  let crc = directory.u32(), let compressed = directory.u32(), let uncompressed = directory.u32(),
                  let nameLength = directory.u16(), let extraLength = directory.u16(), let commentLength = directory.u16(),
                  directory.skip(8), let offset = directory.u32(), let nameBytes = directory.take(Int(nameLength)),
                  directory.skip(Int(extraLength) + Int(commentLength))
            else { throw ZipReadError.truncated }
            if flags & 0x1 != 0 { throw ZipReadError.unsupported("encrypted entry") }
            entries.append(
                Entry(
                    name: String(decoding: nameBytes, as: UTF8.self), method: method, crc32: crc,
                    compressedSize: Int(compressed), uncompressedSize: Int(uncompressed), localHeaderOffset: Int(offset)))
        }
        self.entries = entries
    }

    public func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// The uncompressed contents of an entry, CRC-checked.
    public func contents(of entry: Entry) throws -> Data {
        var reader = ByteReader(bytes: bytes, offset: entry.localHeaderOffset)
        guard let signature = reader.u32(), signature == 0x0403_4B50, reader.skip(22), let nameLength = reader.u16(),
              let extraLength = reader.u16(), reader.skip(Int(nameLength) + Int(extraLength)),
              let raw = reader.take(entry.compressedSize)
        else { throw ZipReadError.truncated }
        let output: Data
        switch entry.method {
        case 0:
            output = Data(raw)
        case 8:
            guard entry.uncompressedSize <= 256 * 1024 * 1024 else { throw ZipReadError.unsupported("entry too large") }
            output = try Self.inflate(raw, expectedSize: entry.uncompressedSize)
        default:
            throw ZipReadError.unsupported("compression method \(entry.method)")
        }
        guard output.count == entry.uncompressedSize, CRC32.checksum(output) == entry.crc32 else {
            throw ZipReadError.crcMismatch(entry.name)
        }
        return output
    }

    public func contents(named name: String) throws -> Data {
        guard let entry = entry(named: name) else { throw ZipReadError.noSuchEntry(name) }
        return try contents(of: entry)
    }

    private static func inflate(_ raw: [UInt8], expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        var output = [UInt8](repeating: 0, count: expectedSize)
        let written = output.withUnsafeMutableBufferPointer { destination -> Int in
            raw.withUnsafeBufferPointer { source -> Int in
                guard let destinationBase = destination.baseAddress, let sourceBase = source.baseAddress else { return 0 }
                return compression_decode_buffer(destinationBase, expectedSize, sourceBase, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw ZipReadError.truncated }
        return Data(output)
    }
}
