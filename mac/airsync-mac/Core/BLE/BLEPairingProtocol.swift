import Foundation
import CryptoKit

/// QR possession proves both peers before the existing BLE bearer credential is used.
nonisolated enum BLEPairingProtocol {
    static let maximumEnvelopeBytes = 2048
    static let maximumPlaintextBytes = 1024
    static let windowDuration: TimeInterval = 120

    struct Payload: Codable {
        let v: Int
        let action: String
        let pairing: String
        let nonce: String
        var token: String?
        var deviceID: String?
        var name: String?

        var isValid: Bool {
            guard v == 1, UUID(uuidString: pairing) != nil, UUID(uuidString: nonce) != nil else { return false }
            if action == "request" { return token == nil && deviceID == nil && name == nil }
            guard let token = token, (16...256).contains(token.utf8.count),
                  token.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { return false }
            if action == "confirm" { return deviceID == nil && name == nil }
            guard action == "response",
                  let deviceID = deviceID, (1...128).contains(deviceID.utf8.count),
                  let name = name, (1...256).contains(name.utf8.count),
                  !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return true
        }
    }

    private struct Envelope: Codable {
        let type: String
        let encrypted: String
    }

    static func encode(_ payload: Payload, key: Data) -> String? {
        guard key.count == 32, payload.isValid,
              let plaintext = try? JSONEncoder().encode(payload), plaintext.count <= maximumPlaintextBytes,
              let box = try? AES.GCM.seal(plaintext, using: SymmetricKey(data: key)), let combined = box.combined,
              let bytes = try? JSONEncoder().encode(Envelope(type: "blePairing", encrypted: combined.base64EncodedString())),
              bytes.count <= maximumEnvelopeBytes else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    static func decode(_ text: String, key: Data) -> Payload? {
        guard key.count == 32, text.utf8.count <= maximumEnvelopeBytes,
              let bytes = text.data(using: .utf8), let envelope = try? JSONDecoder().decode(Envelope.self, from: bytes),
              envelope.type == "blePairing", let combined = Data(base64Encoded: envelope.encrypted),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: key)), plaintext.count <= maximumPlaintextBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: plaintext), payload.isValid else { return nil }
        return payload
    }

    static func response(_ text: String, key: Data, pairing: UUID, nonce: UUID) -> Payload? {
        guard let payload = decode(text, key: key), payload.action == "response",
              UUID(uuidString: payload.pairing) == pairing, UUID(uuidString: payload.nonce) == nonce else { return nil }
        return payload
    }

    static func qrText(pairing: UUID, key: Data, name: String) -> String? {
        guard key.count == 32 else { return nil }
        var components = URLComponents()
        components.scheme = "androp"
        components.host = "pair"
        let items = [URLQueryItem(name: "transport", value: "ble"), URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "name", value: name), URLQueryItem(name: "key", value: key.base64EncodedString()),
            URLQueryItem(name: "pairing", value: pairing.uuidString.lowercased())]
        // Encode '?' as well as '+' because legacy pairing parsers accept '?' separators.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        components.percentEncodedQuery = items.map {
            $0.name + "=" + (($0.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        return components.string
    }

    // MARK: Reconnect after QR pairing
    // Mutual proof over fresh nonces; the token never crosses the air, so a device
    // replaying the phone's advertisement cannot learn anything. Must match
    // BlePairingProtocol.kt.

    static func newReconnectNonce() -> String {
        // UInt8.random draws from the system CSPRNG.
        Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
    }

    private static func validNonce(_ value: String?) -> Bool {
        guard let value, value.count <= 32, let data = Data(base64Encoded: value) else { return false }
        return data.count == 16
    }

    static func reconnectProof(token: String, role: String, first: String, second: String) -> String {
        let key = SymmetricKey(data: Data(token.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("androp-ble-auth|\(role)|\(first)|\(second)".utf8), using: key)
        return Data(mac).base64EncodedString()
    }

    private static func json(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func reconnectHello(nonce: String) -> String? {
        json(["v": 2, "action": "hello", "nonce": nonce])
    }

    /// The phone's nonce when [text] is a challenge that proves the phone holds [token].
    static func verifiedPhoneNonce(challenge text: String, token: String, macNonce: String) -> String? {
        guard !token.isEmpty, text.utf8.count <= maximumPlaintextBytes,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              object["v"] as? Int == 2, object["action"] as? String == "challenge",
              let phoneNonce = object["nonce"] as? String, validNonce(phoneNonce),
              let proof = object["proof"] as? String else { return nil }
        let expected = reconnectProof(token: token, role: "phone", first: macNonce, second: phoneNonce)
        // Constant-time comparison of equal-length ASCII strings.
        let a = Array(proof.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return nil }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0 ? phoneNonce : nil
    }

    static func reconnectAuth(token: String, macNonce: String, phoneNonce: String) -> String? {
        json(["v": 2, "action": "auth", "proof": reconnectProof(token: token, role: "mac", first: phoneNonce, second: macNonce)])
    }
}
