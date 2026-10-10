import Foundation
import CryptoKit

/// Credentials are encrypted with the existing pairing key, never the BLE
/// bearer token. Unique request IDs bind responses to one transfer session.
nonisolated enum TransferNetworkProtocol {
    static let maximumEnvelopeBytes = 8 * 1024
    static let actions: Set<String> = ["request", "start", "ready", "error", "stop", "keepAlive", "connected"]

    static func encode(_ payload: [String: Any], key: Data) -> String? {
        guard [16, 24, 32].contains(key.count), valid(payload),
              let plain = try? JSONSerialization.data(withJSONObject: payload), plain.count <= 4096,
              let sealed = try? AES.GCM.seal(plain, using: SymmetricKey(data: key)),
              let combined = sealed.combined,
              let envelope = try? JSONSerialization.data(withJSONObject: ["type": "transferNetwork", "data": ["encrypted": combined.base64EncodedString()]]),
              envelope.count <= maximumEnvelopeBytes else { return nil }
        return String(data: envelope, encoding: .utf8)
    }

    static func decode(_ envelope: String, key: Data) -> [String: Any]? {
        guard [16, 24, 32].contains(key.count), envelope.utf8.count <= maximumEnvelopeBytes,
              let bytes = envelope.data(using: .utf8),
              let outer = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              outer["type"] as? String == "transferNetwork",
              let data = outer["data"] as? [String: Any], let encrypted = data["encrypted"] as? String,
              let combined = Data(base64Encoded: encrypted),
              let sealed = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(sealed, using: SymmetricKey(data: key)), plain.count <= 4096,
              let payload = try? JSONSerialization.jsonObject(with: plain) as? [String: Any], valid(payload) else { return nil }
        return payload
    }

    static func valid(_ payload: [String: Any]) -> Bool {
        guard payload["v"] as? Int == 1, let id = payload["id"] as? String, UUID(uuidString: id) != nil,
              let action = payload["action"] as? String, actions.contains(action) else { return false }
        if action == "ready" {
            guard let ssid = payload["ssid"] as? String, HotspotWiFiPolicy.validSSID(ssid),
                  let password = payload["password"] as? String,
                  (8...63).contains(password.utf8.count),
                  password.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) else { return false }
        }
        return true
    }
}
