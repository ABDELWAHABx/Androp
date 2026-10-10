import Foundation

/// Validates wire data before allocating network/decoder buffers. Reads byte-by-byte:
/// Data (including small inline Data and slices) does not guarantee integer alignment.
enum ScrcpyPacketParser {
    static let maximumPacketSize = 32 * 1024 * 1024
    static let maximumDimension: UInt32 = 16_384

    enum Header: Equatable {
        case session(width: UInt32, height: UInt32)
        case media(size: Int, isConfig: Bool, isKeyframe: Bool, pts: UInt64)
    }

    static func header(_ data: Data) -> Header? {
        guard data.count == 12 else { return nil }
        let bytes = Array(data)
        func integer(_ range: Range<Int>) -> UInt64 {
            bytes[range].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        if bytes[0] & 0x80 != 0 {
            let width = UInt32(integer(4..<8))
            let height = UInt32(integer(8..<12))
            guard width > 0, height > 0,
                  width <= maximumDimension, height <= maximumDimension else { return nil }
            return .session(width: width, height: height)
        }
        let flags = integer(0..<8)
        let size = integer(8..<12)
        guard size > 0, size <= UInt64(maximumPacketSize) else { return nil }
        return .media(size: Int(size), isConfig: flags & (1 << 62) != 0,
                      isKeyframe: flags & (1 << 61) != 0, pts: flags & 0x1FFF_FFFF_FFFF_FFFF)
    }

    /// Handles both three- and four-byte Annex-B delimiters, including mixed streams.
    static func nalUnits(_ data: Data) -> [Data] {
        guard !data.isEmpty, data.count <= maximumPacketSize else { return [] }
        let bytes = Array(data)
        var ranges: [Range<Int>] = []
        var start: Int?
        var index = 0
        while index + 2 < bytes.count {
            let prefix: Int
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                prefix = 3
            } else if index + 3 < bytes.count, bytes[index] == 0,
                      bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                prefix = 4
            } else {
                index += 1
                continue
            }
            if let start, index > start { ranges.append(start..<index) }
            // A malformed packet must not create millions of tiny allocations.
            guard ranges.count < 1_024 else { return [] }
            start = index + prefix
            index += prefix
        }
        if let start {
            if start < bytes.count { ranges.append(start..<bytes.count) }
        } else {
            ranges.append(0..<bytes.count)
        }
        return ranges.map { Data(bytes[$0]) }
    }

    static func avcc(_ data: Data) -> Data? {
        let units = nalUnits(data)
        guard !units.isEmpty else { return nil }
        var result = Data()
        for unit in units {
            var size = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
            result.append(unit)
        }
        return result
    }
}
