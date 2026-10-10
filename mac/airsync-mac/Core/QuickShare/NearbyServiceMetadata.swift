import Foundation

/// Validates bytes advertised by untrusted Nearby peers before constructing device records.
enum NearbyServiceMetadata {
    static func endpointID(in data: Data) -> String? {
        guard data.count >= 10, data[0] == 0x23,
              data.subdata(in: 5..<8) == Data([0xFC, 0x9F, 0x5E]),
              let id = String(data: data.subdata(in: 1..<5), encoding: .ascii),
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            return nil
        }
        return id
    }

    static func extensionRecords(in data: Data, offset: Int) -> [UInt8: Data]? {
        guard offset >= 0 && offset <= data.count else { return nil }
        var offset = offset
        var records: [UInt8: Data] = [:]
        while offset < data.count {
            guard data.count - offset >= 2 else { return nil }
            let type = data[offset]
            let length = Int(data[offset + 1])
            offset += 2
            guard length <= data.count - offset else { return nil }
            records[type] = data.subdata(in: offset..<(offset + length))
            offset += length
        }
        return records
    }

    static func encodedName(_ name: String?) -> Data {
        // Trim complete Unicode scalars so a long device name remains valid UTF-8.
        var result = Data()
        for scalar in (name ?? "").unicodeScalars {
            let bytes = Data(String(scalar).utf8)
            if bytes.count > 255 - result.count { break }
            result.append(bytes)
        }
        return result
    }
}
