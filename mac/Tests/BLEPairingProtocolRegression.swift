import Foundation

@main
struct BLEPairingProtocolRegression {
    static func main() throws {
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            count += 1
        }
        let key = Data(0..<32)
        let pairing = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let nonce = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let request = BLEPairingProtocol.Payload(v: 1, action: "request", pairing: pairing.uuidString, nonce: nonce.uuidString)
        let encoded = BLEPairingProtocol.encode(request, key: key)!
        expect(BLEPairingProtocol.decode(encoded, key: key)?.action == "request", "request must round trip")
        expect(BLEPairingProtocol.decode(encoded, key: Data(repeating: 3, count: 32)) == nil, "wrong QR key rejected")
        expect(BLEPairingProtocol.response(encoded, key: key, pairing: pairing, nonce: nonce) == nil, "reflected request rejected")
        expect(BLEPairingProtocol.encode(request, key: Data()) == nil, "invalid key rejected")
        let vector = #"{"type":"blePairing","encrypted":"AAECAwQFBgcICQoLPCCgOf/U7jnsIuPi3odaV6Gk4keAFDEPXUXJp20IacBofsneleMjqUWVTty5tgUJ32hRoG7nkusSrxsoKc7E38EN90vi4BdQLWWIQs3hYYZb7+tYVFFhWs/PrP5K3Yu/+cp00pZz+jemLgyAZUcTTYhVUJnR9xeof9177/aJBWvVcDrkhOb5YDzUfpYQ4nWjVNmAUVB3vnq9bdtazuff2auu/3eKm6kYhU//nrr279j4h44AsYkA3QistakW6MOWYDinnmirv6pSdP/E1CC04cNE2iVcbcmEH/a6lHN5r7wGAalJG+VfJy93xA81PELTQDL5"}"#
        let requestVector = #"{"type":"blePairing","encrypted":"AAECAwQFBgcICQoLPCCgOf/U7jnsIuPi3odaV6Gk4kWFHiwIGkvH9XwActtvd4zGjfAjqUWVTty5qhkJ32hNuWvnkvcHphsoNdLE38EN90vi4BdQLXaGTIHgYItdqPNARFFhWs/PrP5Vwou/+dVt1JZz5SKsLgyfekcTTYhVUJnR9xeob4J0/OAwd4KRt/aJbk7orUOK"}"#
        let confirmVector = #"{"type":"blePairing","encrypted":"AAECAwQFBgcICQoLPCCgOf/U7jnsIuPi3odaV6G16FqWEi0RGkvH9XwActtvd4zGjfAjqUWVTty5qhkJ32hNuWvnkvcHphsoNdLE38EN90vi4BdQLXaGTIHgYItdqPNARFFhWs/PrP5Vwou/+dVt1JZz5SKsLgyfekcTTYhVUJnR9xeob9N1ue2NC2CZaCL2heX4Zz3Xf4wF4y2gG5eHUFM8o3u+bMVDz+Te1qr2/HaNmqpc2gT7FifEjKqh12ro1aBB3sI="}"#
        expect(BLEPairingProtocol.decode(requestVector, key: key)?.action == "request", "Android request fixture decodes")
        expect(BLEPairingProtocol.decode(confirmVector, key: key)?.action == "confirm", "Android confirmation fixture decodes")
        expect(BLEPairingProtocol.response(confirmVector, key: key, pairing: pairing, nonce: nonce) == nil, "confirmation cannot replace the response")
        let response = BLEPairingProtocol.response(vector, key: key, pairing: pairing, nonce: nonce)
        expect(response?.deviceID == "samsung-test-device", "Android-compatible AES-GCM response decodes")
        expect(response?.token == "01234567-89ab-cdef-0123-456789abcdef", "bearer credential remains inside encrypted proof")
        expect(BLEPairingProtocol.response(vector, key: key, pairing: UUID(), nonce: nonce) == nil, "old QR session rejected")
        expect(BLEPairingProtocol.response(vector, key: key, pairing: pairing, nonce: UUID()) == nil, "replayed candidate nonce rejected")
        expect(BLEPairingProtocol.decode(vector.replacingOccurrences(of: "AAECAw", with: "BAECAw"), key: key) == nil, "tampering rejected")
        expect(BLEPairingProtocol.decode(vector.replacingOccurrences(of: "blePairing", with: "transferNetwork"), key: key) == nil, "wrong message purpose rejected")
        expect(BLEPairingProtocol.decode(String(repeating: "a", count: 2049), key: key) == nil, "oversized envelope rejected")
        var invalid = response!
        invalid.token = "short"
        expect(!invalid.isValid, "short bearer credential rejected")
        invalid.token = String(repeating: "a", count: 257)
        expect(!invalid.isValid, "oversized bearer credential rejected")
        invalid = response!
        invalid.deviceID = " "
        expect(!invalid.isValid, "blank identity rejected")
        invalid = response!
        invalid.name = String(repeating: "字", count: 86)
        expect(!invalid.isValid, "name is bounded by UTF8 bytes")
        let unknownVersion = BLEPairingProtocol.Payload(v: 2, action: "request", pairing: pairing.uuidString, nonce: nonce.uuidString)
        expect(!unknownVersion.isValid, "unknown version rejected")
        var reflected = request
        reflected.token = response?.token
        expect(!reflected.isValid, "request cannot carry bearer credentials")
        let qr = BLEPairingProtocol.qrText(pairing: pairing, key: Data(repeating: 251, count: 32), name: "Mac & Café + ?")!
        let parsed = URLComponents(string: qr)!
        let parameters = Dictionary(uniqueKeysWithValues: parsed.queryItems!.map { ($0.name, $0.value ?? "") })
        expect(parsed.host == "pair" && parsed.port == nil, "BLE QR has no fake IP endpoint")
        expect(parameters["name"] == "Mac & Café + ?", "QR name is encoded without adding parameters")
        expect(!qr.contains("+"), "form-style decoders preserve base64 plus")
        expect(qr.filter { $0 == "?" }.count == 1, "name cannot add a legacy query separator")
        expect(parameters["key"] == Data(repeating: 251, count: 32).base64EncodedString(), "QR key round trips")
        let chunks = BLEChunkUtil.splitIntoChunks(payload: vector, mtu: 20)
        let assembler = BLEChunkUtil.Reassembler(maximumMessageBytes: 2048)
        var assembled: String?
        for chunk in chunks { if let text = assembler.add(chunk) { assembled = text } }
        expect(assembled == vector, "proof works with minimum ATT payload")
        let small = BLEChunkUtil.Reassembler(maximumMessageBytes: 8)
        expect(small.add(Data([0, 0, 0, 1]) + Data(repeating: 65, count: 9)) == nil, "pre-auth reassembly is bounded")
        print("BLE QR pairing: \(count) checks passed")
    }
}
