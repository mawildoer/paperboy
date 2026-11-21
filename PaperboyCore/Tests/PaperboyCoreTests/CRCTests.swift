import Foundation
import Testing

@testable import PaperboyCore

@Suite struct CRC32Tests {
    @Test func knownAnswers() {
        #expect(CRC32.checksum(Data()) == 0x0000_0000)
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)  // the standard check value
        #expect(CRC32.checksum(Data("a".utf8)) == 0xE8B7_BE43)
        #expect(CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
        #expect(CRC32.checksum(Data(repeating: 0, count: 32)) == 0x190A_55AD)
        #expect(CRC32.checksum(Data(repeating: 0xFF, count: 32)) == 0xFF6C_AB0B)
    }

    @Test func incrementalMatchesOneShot() {
        let data = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        var running: UInt32 = 0
        var offset = 0
        for size in [1, 2, 3, 500, 4096, 5398] {
            running = CRC32.update(running, data.subdata(in: offset..<(offset + size)))
            offset += size
        }
        #expect(offset == data.count)
        #expect(running == CRC32.checksum(data))
    }

    @Test func worksOnDataSlices() {
        let data = Data("xx123456789yy".utf8)
        #expect(CRC32.checksum(data[2..<11]) == 0xCBF4_3926)
    }
}
