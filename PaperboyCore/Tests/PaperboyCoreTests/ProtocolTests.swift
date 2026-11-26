import Foundation
import Testing

@testable import PaperboyCore

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined(separator: " ")
}

private func bytes(_ text: String) -> Data {
    Data(text.split(separator: " ").compactMap { UInt8($0, radix: 16) })
}

private let sampleID = ArticleID(hex: "0102030405060708")!

@Suite struct ArticleIDTests {
    @Test func derivedFromSHA256OfCanonicalURL() {
        // Reference values from `printf %s URL | shasum -a 256`.
        #expect(ArticleID(canonicalURL: "https://example.com/p/hello").hex == "840a2b4fa8bd708b")
        #expect(ArticleID(canonicalURL: "https://www.nytimes.com/2026/11/15/world/example.html").hex == "0fe2f7f997b9d0cc")
        #expect(ArticleID(canonicalURL: "").hex == "e3b0c44298fc1c14")
    }

    @Test func bytesAreInWireOrder() {
        let id = ArticleID(canonicalURL: "https://example.com/p/hello")
        #expect(id.bytes == [0x84, 0x0A, 0x2B, 0x4F, 0xA8, 0xBD, 0x70, 0x8B])
        #expect(ArticleID(bytes: id.bytes) == id)
        #expect(ArticleID(hex: "840A2B4FA8BD708B") == id)
        #expect(ArticleID(hex: "0000000000000001")?.hex == "0000000000000001")
    }

    @Test func rejectsBadInput() {
        #expect(ArticleID(hex: "840a2b4fa8bd708") == nil)
        #expect(ArticleID(hex: "840a2b4fa8bd708bb") == nil)
        #expect(ArticleID(hex: "+40a2b4fa8bd708b") == nil)
        #expect(ArticleID(hex: "zz0a2b4fa8bd708b") == nil)
        #expect(ArticleID(bytes: [1, 2, 3]) == nil)
    }

    @Test func codableAsHexString() throws {
        let id = ArticleID(canonicalURL: "https://example.com/p/hello")
        let json = try JSONEncoder().encode([id])
        #expect(String(decoding: json, as: UTF8.self) == "[\"840a2b4fa8bd708b\"]")
        #expect(try JSONDecoder().decode([ArticleID].self, from: json) == [id])
    }

    @Test func canonicalizerStripsTrackingAndFragments() {
        #expect(URLCanonicalizer.canonicalize("HTTPS://Example.com/p/hello/?utm_source=x#frag") == "https://example.com/p/hello")
        #expect(URLCanonicalizer.canonicalize("https://example.com/") == "https://example.com/")
        #expect(URLCanonicalizer.canonicalize("  https://example.com/a%20b.html  ") == "https://example.com/a%20b.html")
        #expect(URLCanonicalizer.canonicalize("not a url") == "not a url")
    }
}

@Suite struct FrameVectorTests {
    /// Every frame in DESIGN.md with its exact bytes.
    static let vectors: [(Frame, String)] = [
        // HELLO: version 1, unix time 0x6918B4C0 little-endian.
        (.hello(version: 1, unixTime: 0x6918_B4C0), "01 01 c0 b4 18 69"),
        (.list, "02"),
        (.touch(SyncTouch(id: sampleID, nonce: 0x01020304)), "21 01 02 03 04 05 06 07 08 04 03 02 01"),
        (.touchResult(.ok), "a1 00"),
        // PUT_BEGIN: id, size 70000 (0x00011170), crc 0xDEADBEEF, time 0x6918B4C0, "NYT", "Hi é", "Al".
        (
            .putBegin(
                PutBegin(id: sampleID, size: 70_000, crc32: 0xDEAD_BEEF, time: 0x6918_B4C0, source: "NYT", title: "Hi é", author: "Al")),
            "10 01 02 03 04 05 06 07 08 70 11 01 00 ef be ad de c0 b4 18 69 03 4e 59 54 05 48 69 20 c3 a9 02 41 6c"
        ),
        (.putBegin(PutBegin(id: sampleID, size: 0, crc32: 0, time: 0, source: "", title: "", author: "")),
         "10 01 02 03 04 05 06 07 08 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"),
        (.putData(Data([0xAA, 0xBB, 0xCC])), "11 aa bb cc"),
        (.putData(Data()), "11"),
        (.putEnd, "12"),
        (.delete(sampleID), "20 01 02 03 04 05 06 07 08"),
        (.bye, "30"),
        // HELLO_ACK: version 1, battery 87, 1234 MB free (0x04D2), "1.2".
        (.helloAck(HelloAck(version: 1, batteryPercent: 87, freeSpaceMB: 1234, firmwareVersion: "1.2")), "81 01 57 d2 04 00 00 31 2e 32"),
        (.helloAck(HelloAck(version: 1, batteryPercent: 0, freeSpaceMB: 0, firmwareVersion: "")), "81 01 00 00 00 00 00"),
        (
            .listItems([ListItem(id: sampleID, flags: 1), ListItem(id: ArticleID(hex: "ffeeddccbbaa9988")!, flags: 0)]),
            "82 01 02 03 04 05 06 07 08 01 ff ee dd cc bb aa 99 88 00"
        ),
        (.listItems([]), "82"),
        (.listEnd(total: 258), "83 02 01"),
        (.putReady(.ok), "90 00"),
        (.putReady(.exists), "90 06"),
        (.putProgress(8192), "91 00 20 00 00"),
        (.putResult(.checksumMismatch), "92 04"),
        (.deleteResult(.storageError), "a0 03"),
    ]

    @Test func encodeMatchesVectors() throws {
        for (frame, expected) in Self.vectors {
            #expect(hex(try frame.encode()) == expected, "\(frame.logDescription)")
        }
    }

    @Test func decodeMatchesVectors() throws {
        for (frame, encoded) in Self.vectors {
            #expect(try Frame.decode(bytes(encoded)) == frame, "\(encoded)")
        }
    }

    @Test func typeBytes() {
        let expected: [(FrameType, UInt8)] = [
            (.hello, 0x01), (.list, 0x02), (.putBegin, 0x10), (.putData, 0x11), (.putEnd, 0x12), (.delete, 0x20), (.bye, 0x30),
            (.helloAck, 0x81), (.listItems, 0x82), (.listEnd, 0x83), (.putReady, 0x90), (.putProgress, 0x91), (.putResult, 0x92),
            (.deleteResult, 0xA0), (.touch, 0x21), (.touchResult, 0xA1),
        ]
        #expect(expected.count == FrameType.allCases.count)
        for (type, byte) in expected { #expect(type.rawValue == byte) }
        #expect(SyncProtocol.version == 2)
        #expect(SyncProtocol.serviceUUID == "8E400001-7B2A-4B1F-9C5D-5A1EF0C0DE01")
        #expect(SyncProtocol.rxCharacteristicUUID == "8E400002-7B2A-4B1F-9C5D-5A1EF0C0DE01")
        #expect(SyncProtocol.txCharacteristicUUID == "8E400003-7B2A-4B1F-9C5D-5A1EF0C0DE01")
        #expect(SyncProtocol.flowControlWindow == 8192)
    }

    @Test func statusValues() {
        #expect(SyncStatus.ok.rawValue == 0)
        #expect(SyncStatus.busy.rawValue == 1)
        #expect(SyncStatus.noSpace.rawValue == 2)
        #expect(SyncStatus.storageError.rawValue == 3)
        #expect(SyncStatus.checksumMismatch.rawValue == 4)
        #expect(SyncStatus.badRequest.rawValue == 5)
        #expect(SyncStatus.exists.rawValue == 6)
        // An unknown status still decodes.
        #expect(try! Frame.decode(bytes("92 63")) == .putResult(SyncStatus(rawValue: 99)))
    }

    @Test func rejectsMalformedFrames() {
        #expect(throws: FrameError.empty) { try Frame.decode(Data()) }
        #expect(throws: FrameError.unknownType(0x7F)) { try Frame.decode(bytes("7f 00")) }
        let malformed = [
            "01 01 c0 b4 18",  // HELLO one byte short
            "01 01 c0 b4 18 69 00",  // HELLO one byte long
            "02 00",  // LIST with a payload
            "10 01 02 03 04 05 06 07 08 70 11 01 00",  // PUT_BEGIN cut in the fixed part
            "10 01 02 03 04 05 06 07 08 00 00 00 00 00 00 00 00 00 00 00 00 03 4e 59",  // string runs off the end
            "10 01 02 03 04 05 06 07 08 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 99",  // trailing byte
            "20 01 02 03",  // DELETE with a short id
            "81 01 57 d2 04",  // HELLO_ACK cut
            "82 01 02 03 04 05 06 07 08",  // LIST_ITEMS not a multiple of 9
            "83 02",  // LIST_END short
            "90",  // PUT_READY without status
            "91 00 20 00",  // PUT_PROGRESS short
            "a0 00 00",  // DELETE_RESULT long
        ]
        for text in malformed {
            #expect(throws: FrameError.self, "\(text)") { try Frame.decode(bytes(text)) }
        }
    }

    @Test func rejectsInvalidUTF8AndLongStrings() {
        // title = FF FE (not UTF-8)
        let bad = "10 01 02 03 04 05 06 07 08 00 00 00 00 00 00 00 00 00 00 00 00 00 02 ff fe 00"
        #expect(throws: FrameError.invalidUTF8(field: "title")) { try Frame.decode(bytes(bad)) }
        let long = String(repeating: "x", count: 256)
        #expect(throws: FrameError.stringTooLong(field: "title", bytes: 256)) {
            try Frame.putBegin(PutBegin(id: sampleID, size: 1, crc32: 1, time: 1, source: "", title: long, author: "")).encode()
        }
    }

    @Test func longestPutBeginRoundTrips() throws {
        let begin = PutBegin(
            id: sampleID, size: .max, crc32: .max, time: .max, source: String(repeating: "s", count: 255),
            title: String(repeating: "é", count: 127), author: String(repeating: "a", count: 255))
        let encoded = try Frame.putBegin(begin).encode()
        #expect(encoded.count == SyncProtocol.putBeginFixedBytes + 255 + 254 + 255)
        #expect(try Frame.decode(encoded) == .putBegin(begin))
    }

    @Test func textHelpers() {
        #expect(SyncText.truncate("héllo", maxBytes: 2) == "h")  // never splits the two-byte é
        #expect(SyncText.truncate("héllo", maxBytes: 3) == "hé")
        #expect(SyncText.truncate("hello", maxBytes: 99) == "hello")
        #expect(SyncText.truncate("hello", maxBytes: 0) == "")
        #expect(SyncText.truncate("👨‍👩‍👧x", maxBytes: 5) == "")  // a family emoji is one character of 18 bytes
        #expect(SyncText.sanitizeField("  A\ttitle\nwith\r\nbreaks \u{0} ") == "A title with breaks")
    }
}
