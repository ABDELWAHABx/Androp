import Foundation
import CryptoKit

@main
struct TransferNetworkProtocolRegression {
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        let id = "01234567-89ab-cdef-0123-456789abcdef"
        let key = Data((0..<32).map(UInt8.init))
        let ready: [String: Any] = ["v": 1, "id": id, "action": "ready", "ssid": "Androp-é", "password": "testPass123"]
        func outer(_ combined: Data, type: String = "transferNetwork") throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: ["type": type,
                "data": ["encrypted": combined.base64EncodedString()]]), encoding: .utf8)!
        }
        func sealRaw(_ bytes: Data) throws -> String {
            try outer(AES.GCM.seal(bytes, using: SymmetricKey(data: key)).combined!)
        }
        func invalid(_ field: String, _ value: Any) throws {
            var payload = ready
            payload[field] = value
            expect(TransferNetworkProtocol.encode(payload, key: key) == nil, "encoder rejects invalid \(field)")
            let raw = try sealRaw(JSONSerialization.data(withJSONObject: payload))
            expect(TransferNetworkProtocol.decode(raw, key: key) == nil, "authenticated malformed \(field) remains invalid")
        }

        for length in [16, 24, 32] {
            let supportedKey = Data(repeating: UInt8(length), count: length)
            let envelope = TransferNetworkProtocol.encode(ready, key: supportedKey)!
            let decoded = TransferNetworkProtocol.decode(envelope, key: supportedKey)!
            expect(NSDictionary(dictionary: decoded).isEqual(to: ready), "supported AES key roundtrip")
            expect(!envelope.contains("testPass123"), "password is not exposed in the envelope")
        }
        let envelope = TransferNetworkProtocol.encode(ready, key: key)!
        expect(envelope != TransferNetworkProtocol.encode(ready, key: key), "fresh encryption nonce per message")
        expect(TransferNetworkProtocol.decode(envelope, key: Data(repeating: 99, count: 32)) == nil, "wrong pairing key rejected")
        for length in [0, 15, 17, 31, 33] {
            let invalidKey = Data(repeating: 0, count: length)
            expect(TransferNetworkProtocol.encode(ready, key: invalidKey) == nil, "invalid AES key length rejected on encode")
            expect(TransferNetworkProtocol.decode(envelope, key: invalidKey) == nil, "invalid AES key length rejected on decode")
        }

        // Generated with Java JCE AES/GCM/NoPadding, 128-bit tag, key bytes
        // 00...1f and nonce a0...ab. Android CryptoUtil uses exactly this
        // nonce || ciphertext || tag wire layout and UTF-8 JSON. This fixed
        // fixture catches incompatible layouts even if same-platform roundtrip passes.
        let javaCombined = Data(base64Encoded: "oKGio6SlpqeoqaqrnToKD3/6Lp0LAaXpJUrx7EOYbCalmnpV/WwL5RvOEyziR3XMghZmC2ikPalrGeecITlqagOzbhcuMClkhgLg0dDFp0MS1peJkMDFOs6gqMiie4ZnbOO1WJ4UTenG9T/wrb4J32bd+8v/qHVht7vPVedD7DGT7oGa0s63JUlW0dc=")!
        let javaDecoded = TransferNetworkProtocol.decode(try outer(javaCombined), key: key)
        expect(javaDecoded != nil && NSDictionary(dictionary: javaDecoded!).isEqual(to: ready), "Android-compatible JCE vector decodes exactly")
        for offset in [0, 12, javaCombined.count - 1] {
            var corrupted = javaCombined
            corrupted[offset] ^= 1
            expect(TransferNetworkProtocol.decode(try outer(corrupted), key: key) == nil, "tampered nonce/ciphertext/tag rejected")
        }
        expect(TransferNetworkProtocol.decode(try outer(javaCombined, type: "clipboard"), key: key) == nil, "envelope type bound")
        expect(TransferNetworkProtocol.decode(try outer(Data(javaCombined.prefix(20))), key: key) == nil, "truncated sealed box rejected")
        for malformed in ["", "not-json", "[]", "{}", "{\"type\":\"transferNetwork\",\"data\":{\"encrypted\":\"!invalid!\"}}"] {
            expect(TransferNetworkProtocol.decode(malformed, key: key) == nil, "malformed envelope rejected")
        }
        for action in ["request", "start", "ready", "error", "stop", "keepAlive", "connected"] {
            var payload = ready
            payload["action"] = action
            expect(TransferNetworkProtocol.encode(payload, key: key) != nil, "supported protocol action")
        }
        for value in ["", "enableInternetHotspot", "READY"] { try invalid("action", value) }
        for value in ["", "1234", "01234567-89ab-cdef-0123-456789abcdeg"] { try invalid("id", value) }
        for value in [0, 2, -1] { try invalid("v", value) }
        try invalid("v", "1")
        for value in ["", String(repeating: "a", count: 33), String(repeating: "é", count: 17), "bad\nssid"] { try invalid("ssid", value) }
        for value in ["short", String(repeating: "a", count: 64), "bad\npass", "testépass", String(repeating: "é", count: 32)] { try invalid("password", value) }
        for ssid in [String(repeating: "a", count: 32), String(repeating: "é", count: 16), " Phone "] {
            var payload = ready; payload["ssid"] = ssid
            expect(TransferNetworkProtocol.encode(payload, key: key) != nil, "SSID UTF-8 boundary and whitespace accepted")
        }
        for password in [String(repeating: "a", count: 8), String(repeating: "a", count: 63)] {
            var payload = ready; payload["password"] = password
            expect(TransferNetworkProtocol.encode(payload, key: key) != nil, "ASCII password length boundary accepted")
        }

        let padded = envelope + String(repeating: " ", count: 8192 - envelope.utf8.count)
        expect(TransferNetworkProtocol.decode(padded, key: key) != nil, "maximum envelope byte count accepted")
        expect(TransferNetworkProtocol.decode(padded + " ", key: key) == nil, "oversized envelope rejected before decryption")
        let prefix = "{\"v\":1,\"id\":\"\(id)\",\"action\":\"error\",\"message\":\""
        let suffix = "\"}"
        let maximum = prefix + String(repeating: "a", count: 4096 - prefix.utf8.count - suffix.utf8.count) + suffix
        expect(TransferNetworkProtocol.decode(try sealRaw(Data(maximum.utf8)), key: key) != nil, "maximum plaintext byte count accepted")
        let oversized = prefix + String(repeating: "a", count: 4097 - prefix.utf8.count - suffix.utf8.count) + suffix
        expect(TransferNetworkProtocol.decode(try sealRaw(Data(oversized.utf8)), key: key) == nil, "authenticated oversized plaintext rejected")
        let oversizedPayload = try JSONSerialization.jsonObject(with: Data(oversized.utf8)) as! [String: Any]
        expect(TransferNetworkProtocol.encode(oversizedPayload, key: key) == nil, "oversized outgoing plaintext rejected")
        print("Transfer network protocol: \(checks) checks passed")
    }
}
