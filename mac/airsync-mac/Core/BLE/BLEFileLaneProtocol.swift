import Foundation
import CryptoKit

/// Bluetooth file lane: small files over an L2CAP channel when there is no Wi-Fi, instead of
/// starting a temporary hotspot. The Mac always opens the channel (Apple allows only the central
/// to), then sends a plaintext preamble [u16 length]["androp-lane:1:" + id]. Both sides derive that
/// transfer's key as HMAC-SHA256(pairing key, "androp-file-lane:v1:" + id) and exchange
/// BulkTransferProtocol records with it. The ID is fresh per transfer, so a key is never reused.
/// Must match BleFileLaneProtocol.kt.
nonisolated enum BLEFileLaneProtocol {
    /// Bigger selections are faster over the temporary Wi-Fi network.
    static let maximumLaneBytes: Int64 = 16 * 1024 * 1024
    /// Small records keep progress smooth at Bluetooth speed.
    static let recordBytes = 32 * 1024
    private static let preamblePrefix = "androp-lane:1:"

    static func fits(totalBytes: Int64) -> Bool { (0...maximumLaneBytes).contains(totalBytes) }

    static func validID(_ id: String) -> Bool {
        (1...128).contains(id.count) && id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }

    static func deriveKey(pairingKeyBase64: String, id: String) -> SymmetricKey? {
        guard validID(id),
              let pairingKey = Data(base64Encoded: pairingKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              pairingKey.count == 32 else { return nil }
        let code = HMAC<SHA256>.authenticationCode(for: Data("androp-file-lane:v1:\(id)".utf8),
                                                  using: SymmetricKey(data: pairingKey))
        return SymmetricKey(data: Data(code))
    }

    static func preamble(id: String) -> Data {
        let text = Data((preamblePrefix + id).utf8)
        var length = UInt16(text.count).bigEndian
        var frame = Data(bytes: &length, count: 2)
        frame.append(text)
        return frame
    }

    /// A received file name: a single path component, no hidden or reserved names.
    static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && name.utf8.count <= 255 && name != "." && name != ".." &&
            !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !name.contains("\0") && !name.contains(":")
    }
}
