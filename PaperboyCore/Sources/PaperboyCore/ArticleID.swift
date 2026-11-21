import CryptoKit
import Foundation

/// 8-byte article id: the first 8 bytes of SHA-256 of the article's canonical URL.
/// On the device it names the file `/Articles/<16 lowercase hex>.epub`.
public struct ArticleID: Hashable, Sendable, Codable, CustomStringConvertible {
    public static let byteCount = 8

    /// Big-endian packing of the 8 bytes (byte 0 is the most significant), so that
    /// `hex` prints the bytes in wire order.
    private let packed: UInt64

    public init?(bytes: some Collection<UInt8>) {
        guard bytes.count == Self.byteCount else { return nil }
        var value: UInt64 = 0
        for byte in bytes { value = (value << 8) | UInt64(byte) }
        packed = value
    }

    /// The id for a canonical URL. The UTF-8 bytes of the string are hashed verbatim;
    /// run `URLCanonicalizer.canonicalize` first if the URL comes from the wild.
    public init(canonicalURL: String) {
        let digest = SHA256.hash(data: Data(canonicalURL.utf8))
        var value: UInt64 = 0
        for byte in digest.prefix(Self.byteCount) { value = (value << 8) | UInt64(byte) }
        packed = value
    }

    /// Parse 16 hex characters (either case).
    public init?(hex: String) {
        let scalars = Array(hex.utf8)
        guard scalars.count == Self.byteCount * 2, let value = UInt64(hex, radix: 16) else { return nil }
        // UInt64(_:radix:) accepts a leading "+"; reject anything that is not a hex digit.
        guard scalars.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }) else {
            return nil
        }
        packed = value
    }

    /// The 8 bytes in wire order.
    public var bytes: [UInt8] {
        (0..<Self.byteCount).map { UInt8(truncatingIfNeeded: packed >> UInt64(8 * (Self.byteCount - 1 - $0))) }
    }

    /// 16 lowercase hex characters.
    public var hex: String {
        let digits = String(packed, radix: 16)
        return String(repeating: "0", count: Self.byteCount * 2 - digits.count) + digits
    }

    public var description: String { hex }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let id = ArticleID(hex: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a 16-digit hex article id")
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// Light URL normalisation applied before an id is derived, so that the same article reached
/// through different links (tracking parameters, fragments) gets the same id.
/// Only the phone derives ids, so this never has to match anything on the device.
public enum URLCanonicalizer {
    public static func canonicalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), components.host != nil else { return trimmed }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        return components.string ?? trimmed
    }
}
