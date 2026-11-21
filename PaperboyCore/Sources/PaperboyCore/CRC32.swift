import Foundation

/// CRC-32 with the zlib / IEEE 802.3 polynomial (reflected 0xEDB88320),
/// initial value 0xFFFFFFFF and final XOR 0xFFFFFFFF. Same as zlib's `crc32()`.
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    /// Continue a running checksum. Start with `crc = 0`, exactly like zlib.
    public static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = crc ^ 0xFFFF_FFFF
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            table.withUnsafeBufferPointer { t in
                for byte in buffer {
                    c = t[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
                }
            }
        }
        return c ^ 0xFFFF_FFFF
    }

    public static func checksum(_ data: Data) -> UInt32 {
        update(0, data)
    }

    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        update(0, Data(bytes))
    }
}
