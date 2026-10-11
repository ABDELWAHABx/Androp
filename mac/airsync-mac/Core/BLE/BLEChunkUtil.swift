import Foundation

struct BLEChunkUtil {
    static let maxMessageBytes = 256 * 1024
    
    static func splitIntoChunks(payload: String, mtu: Int) -> [Data] {
        guard let data = payload.data(using: .utf8) else { return [] }
        let maxPayloadSize = mtu - BLEConstants.chunkHeaderSize
        
        guard maxPayloadSize > 0, data.count <= maxMessageBytes else { return [] }
        
        let totalChunks = max(1, (data.count + maxPayloadSize - 1) / maxPayloadSize)
        guard totalChunks <= Int(UInt16.max) else { return [] }
        var chunks: [Data] = []
        
        for i in 0..<totalChunks {
            let start = i * maxPayloadSize
            let end = min(start + maxPayloadSize, data.count)
            let chunkData = data.subdata(in: start..<end)
            
            var chunk = Data()
            let index = UInt16(i).bigEndian
            let total = UInt16(totalChunks).bigEndian
            
            withUnsafeBytes(of: index) { chunk.append(contentsOf: $0) }
            withUnsafeBytes(of: total) { chunk.append(contentsOf: $0) }
            
            chunk.append(chunkData)
            chunks.append(chunk)
        }
        
        return chunks
    }
    
    static func reassemble(chunks: [Int: Data]) -> String {
        let sortedIndices = chunks.keys.sorted()
        var combinedData = Data()
        
        for index in sortedIndices {
            if let chunkData = chunks[index] {
                combinedData.append(chunkData)
            }
        }
        
        return String(data: combinedData, encoding: .utf8) ?? ""
    }
    
    static func parseHeader(from data: Data) -> (current: Int, total: Int)? {
        guard data.count >= BLEConstants.chunkHeaderSize else { return nil }
        
        // Byte access avoids UInt16 alignment traps for arbitrary Data slices.
        let bytes = Array(data.prefix(BLEConstants.chunkHeaderSize))
        let current = (Int(bytes[0]) << 8) | Int(bytes[1])
        let total = (Int(bytes[2]) << 8) | Int(bytes[3])
        guard total > 0, current < total else { return nil }
        return (current, total)
    }
    
    static func getPayload(from data: Data) -> Data {
        guard data.count > BLEConstants.chunkHeaderSize else { return Data() }
        return Data(data.dropFirst(BLEConstants.chunkHeaderSize))
    }
    final class Reassembler {
        private let maximumMessageBytes: Int
        private var chunks: [Int: Data] = [:]
        private var totalChunks = 0
        private var byteCount = 0
        private var lastChunkTime = Date.distantPast

        init(maximumMessageBytes: Int = BLEChunkUtil.maxMessageBytes) {
            self.maximumMessageBytes = maximumMessageBytes
        }

        func add(_ packet: Data, now: Date = Date()) -> String? {
            guard let (index, total) = BLEChunkUtil.parseHeader(from: packet) else { clear(); return nil }
            if index == 0 || now.timeIntervalSince(lastChunkTime) > 30 { clear() }
            if totalChunks == 0 {
                guard index == 0 else { return nil }
                totalChunks = total
            }
            guard total == totalChunks, index == chunks.count else { clear(); return nil }
            let payload = BLEChunkUtil.getPayload(from: packet)
            guard total <= maximumMessageBytes, byteCount + payload.count <= maximumMessageBytes else { clear(); return nil }
            chunks[index] = payload
            byteCount += payload.count
            lastChunkTime = now
            guard chunks.count == totalChunks else { return nil }
            let value = BLEChunkUtil.reassemble(chunks: chunks)
            clear()
            return value
        }

        func clear() {
            chunks.removeAll(keepingCapacity: false)
            totalChunks = 0
            byteCount = 0
            lastChunkTime = .distantPast
        }
    }
}
