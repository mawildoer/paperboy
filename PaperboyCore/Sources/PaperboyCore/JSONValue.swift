import Foundation

/// A JSON value that keeps object keys in document order (the NYT body walker depends on it)
/// and comes with a lenient parser for JavaScript-flavoured JSON: bare `undefined` reads as
/// null, raw control characters inside strings are accepted, and anything after the first
/// complete value is ignored.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Member lookup; nil for a missing key, for JSON null, and when `self` is not an object.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let o) = self, let value = o[key], !value.isNull else { return nil }
        return value
    }

    /// Walk a path of keys.
    public func at(_ path: String...) -> JSONValue? {
        var current: JSONValue = self
        for key in path {
            guard let next = current[key] else { return nil }
            current = next
        }
        return current
    }

    /// A string, or a number rendered as a string (ids are sometimes one, sometimes the other).
    public var looseString: String? {
        switch self {
        case .string(let s): return s
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        default: return nil
        }
    }
}

public struct JSONObject: Sendable, Equatable {
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}

    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil { keys.append(key) }
                storage[key] = newValue
            } else if storage[key] != nil {
                storage[key] = nil
                keys.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { keys.count }

    /// Members in document order.
    public var members: [(key: String, value: JSONValue)] {
        keys.compactMap { key in storage[key].map { (key, $0) } }
    }
}

public enum JSONParseError: Error, Equatable, Sendable, CustomStringConvertible {
    case unexpectedEnd
    case unexpectedByte(offset: Int)
    case tooDeep

    public var description: String {
        switch self {
        case .unexpectedEnd: return "JSON ended unexpectedly"
        case .unexpectedByte(let offset): return "unexpected character in JSON at byte \(offset)"
        case .tooDeep: return "JSON is nested too deeply"
        }
    }
}

extension JSONValue {
    public static func parse(_ text: String) throws -> JSONValue {
        try parse(bytes: Array(text.utf8))
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try parse(bytes: [UInt8](data))
    }

    public static func parse(bytes: [UInt8]) throws -> JSONValue {
        var parser = LenientJSONParser(bytes: bytes)
        parser.skipByteOrderMark()
        return try parser.parseValue(depth: 0)
    }
}

private struct LenientJSONParser {
    let bytes: [UInt8]
    var pos = 0
    static let maxDepth = 400

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func skipByteOrderMark() {
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { pos = 3 }
    }

    mutating func skipWhitespace() {
        while pos < bytes.count {
            switch bytes[pos] {
            case 0x20, 0x09, 0x0A, 0x0D: pos += 1
            default: return
            }
        }
    }

    mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth < Self.maxDepth else { throw JSONParseError.tooDeep }
        skipWhitespace()
        guard pos < bytes.count else { throw JSONParseError.unexpectedEnd }
        switch bytes[pos] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectWord("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectWord("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectWord("null"); return .null
        case UInt8(ascii: "u"): try expectWord("undefined"); return .null
        case UInt8(ascii: "N"): try expectWord("NaN"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw JSONParseError.unexpectedByte(offset: pos)
        }
    }

    mutating func expectWord(_ word: String) throws {
        let expected = Array(word.utf8)
        guard pos + expected.count <= bytes.count else { throw JSONParseError.unexpectedEnd }
        for (i, byte) in expected.enumerated() where bytes[pos + i] != byte {
            throw JSONParseError.unexpectedByte(offset: pos + i)
        }
        pos += expected.count
    }

    mutating func parseNumber() throws -> JSONValue {
        let start = pos
        if bytes[pos] == UInt8(ascii: "-") { pos += 1 }
        while pos < bytes.count {
            switch bytes[pos] {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"),
                 UInt8(ascii: "+"), UInt8(ascii: "-"):
                pos += 1
            default:
                return try finishNumber(start: start)
            }
        }
        return try finishNumber(start: start)
    }

    private func finishNumber(start: Int) throws -> JSONValue {
        let text = String(decoding: bytes[start..<pos], as: UTF8.self)
        if text == "-", pos + 8 <= bytes.count, String(decoding: bytes[pos..<(pos + 8)], as: UTF8.self) == "Infinity" {
            throw JSONParseError.unexpectedByte(offset: start)
        }
        guard let value = Double(text) else { throw JSONParseError.unexpectedByte(offset: start) }
        return .number(value)
    }

    mutating func parseString() throws -> String {
        pos += 1  // opening quote
        var out: [UInt8] = []
        while true {
            guard pos < bytes.count else { throw JSONParseError.unexpectedEnd }
            let byte = bytes[pos]
            if byte == UInt8(ascii: "\"") {
                pos += 1
                return String(decoding: out, as: UTF8.self)
            }
            if byte != UInt8(ascii: "\\") {
                out.append(byte)  // raw control characters are accepted, like Python's strict=False
                pos += 1
                continue
            }
            pos += 1
            guard pos < bytes.count else { throw JSONParseError.unexpectedEnd }
            let escape = bytes[pos]
            pos += 1
            switch escape {
            case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
            case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
            case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var unit = try parseHex4()
                var scalarValue = UInt32(unit)
                if unit >= 0xD800, unit <= 0xDBFF {
                    // High surrogate: needs a following \uDC00–\uDFFF.
                    if pos + 1 < bytes.count, bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") {
                        let saved = pos
                        pos += 2
                        let low = try parseHex4()
                        if low >= 0xDC00, low <= 0xDFFF {
                            scalarValue = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                        } else {
                            pos = saved
                            scalarValue = 0xFFFD
                        }
                    } else {
                        scalarValue = 0xFFFD
                    }
                } else if unit >= 0xDC00, unit <= 0xDFFF {
                    unit = 0xFFFD
                    scalarValue = 0xFFFD
                }
                let scalar = Unicode.Scalar(scalarValue) ?? Unicode.Scalar(0xFFFD as UInt16) ?? " "
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
            default:
                // Unknown escape: keep the character itself (JavaScript semantics).
                out.append(escape)
            }
        }
    }

    private mutating func parseHex4() throws -> UInt16 {
        guard pos + 4 <= bytes.count else { throw JSONParseError.unexpectedEnd }
        var value: UInt16 = 0
        for i in 0..<4 {
            let b = bytes[pos + i]
            let digit: UInt16
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt16(b - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt16(b - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt16(b - UInt8(ascii: "A") + 10)
            default: throw JSONParseError.unexpectedByte(offset: pos + i)
            }
            value = (value << 4) | digit
        }
        pos += 4
        return value
    }

    mutating func parseArray(depth: Int) throws -> JSONValue {
        pos += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") {
            pos += 1
            return .array(items)
        }
        while true {
            items.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard pos < bytes.count else { throw JSONParseError.unexpectedEnd }
            if bytes[pos] == UInt8(ascii: ",") {
                pos += 1
                skipWhitespace()
                // Tolerate a trailing comma.
                if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") {
                    pos += 1
                    return .array(items)
                }
                continue
            }
            if bytes[pos] == UInt8(ascii: "]") {
                pos += 1
                return .array(items)
            }
            throw JSONParseError.unexpectedByte(offset: pos)
        }
    }

    mutating func parseObject(depth: Int) throws -> JSONValue {
        pos += 1
        var object = JSONObject()
        skipWhitespace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") {
            pos += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard pos < bytes.count else { throw JSONParseError.unexpectedEnd }
            if bytes[pos] == UInt8(ascii: "}") {  // trailing comma
                pos += 1
                return .object(object)
            }
            guard bytes[pos] == UInt8(ascii: "\"") else { throw JSONParseError.unexpectedByte(offset: pos) }
            let key = try parseString()
            skipWhitespace()
            guard pos < bytes.count else { throw JSONParseError.unexpectedEnd }
            guard bytes[pos] == UInt8(ascii: ":") else { throw JSONParseError.unexpectedByte(offset: pos) }
            pos += 1
            object[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            guard pos < bytes.count else { throw JSONParseError.unexpectedEnd }
            if bytes[pos] == UInt8(ascii: ",") {
                pos += 1
                continue
            }
            if bytes[pos] == UInt8(ascii: "}") {
                pos += 1
                return .object(object)
            }
            throw JSONParseError.unexpectedByte(offset: pos)
        }
    }
}

/// ISO-8601 timestamps as used by Substack (`2024-05-01T12:00:00.000Z`) and NYT.
public enum ISODate {
    public static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) { return date }
        let dayOnly = ISO8601DateFormatter()
        dayOnly.formatOptions = [.withFullDate]
        return dayOnly.date(from: trimmed)
    }

    public static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
