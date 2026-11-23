import Foundation

/// CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320), zlib-compatible.
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    /// Continues a running checksum: `checksum(b, seed: checksum(a)) == checksum(a + b)`.
    public static func checksum(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        var crc = ~seed
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return ~crc
    }

    /// Dedupe key of a clip: CRC over (type UTF-8 bytes + data bytes) of every format, in order.
    /// Stored signed, like upstream.
    public static func clipCRC(_ formats: [ClipFormat]) -> Int32 {
        var crc: UInt32 = 0
        for f in formats {
            crc = checksum(Data(f.type.utf8), seed: crc)
            crc = checksum(f.data, seed: crc)
        }
        return Int32(bitPattern: crc)
    }
}
