import Foundation
import CryptoKit

enum FileTransferProtocol {
    private static func message(_ type: String, _ data: [String: Any]) -> String {
        guard let encoded = try? JSONSerialization.data(withJSONObject: ["type": type, "data": data]),
              let result = String(data: encoded, encoding: .utf8) else { return "" }
        return result
    }

    static func buildInit(id: String, name: String, size: Int64, mime: String, chunkSize: Int, checksum: String?, isClipboard: Bool = false,
                          bulkPort: UInt16? = nil, bulkKey: String? = nil) -> String {
        var data: [String: Any] = ["id": id, "name": name, "size": size, "mime": mime, "chunkSize": chunkSize, "isClipboard": isClipboard]
        // Offer the direct encrypted stream; phones without it ignore these fields.
        if let bulkPort, let bulkKey { data["bulkPort"] = Int(bulkPort); data["bulkKey"] = bulkKey }
        if let checksum, !checksum.isEmpty { data["checksum"] = checksum }
        return message("fileTransferInit", data)
    }
    static func buildChunk(id: String, index: Int, base64Chunk: String) -> String {
        message("fileChunk", ["id": id, "index": index, "chunk": base64Chunk])
    }
    static func buildComplete(id: String, name: String, size: Int64, checksum: String?) -> String {
        var data: [String: Any] = ["id": id, "name": name, "size": size]
        if let checksum, !checksum.isEmpty { data["checksum"] = checksum }
        return message("fileTransferComplete", data)
    }
    static func buildChunkAck(id: String, index: Int) -> String {
        message("fileChunkAck", ["id": id, "index": index])
    }
    static func buildTransferVerified(id: String, verified: Bool) -> String {
        message("transferVerified", ["id": id, "verified": verified])
    }
    static func buildCancel(id: String) -> String { message("fileTransferCancel", ["id": id]) }
    static func buildFilePull(path: String) -> String { message("filePull", ["path": path]) }
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
