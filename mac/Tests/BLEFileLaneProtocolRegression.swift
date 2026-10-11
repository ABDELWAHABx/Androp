import Foundation
import CryptoKit

// Same vector as BleFileLaneProtocolTest.kt: both apps must derive the same per-transfer key.
let pairingKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=" // bytes 0..31
let id = "0A1B2C3D-0000-4000-8000-000000000001"
var failures = 0
func expect(_ condition: Bool, _ message: String) { if !condition { failures += 1; fputs("FAIL: \(message)\n", stderr) } }

let key = BLEFileLaneProtocol.deriveKey(pairingKeyBase64: pairingKey, id: id)
let hex = key.map { $0.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined() }
expect(hex == "915e2b96873a2a5fc3e8149145b87b83417ce43a3ed1338a0938424b5788bb37", "key differs from the Android derivation")
expect(BLEFileLaneProtocol.deriveKey(pairingKeyBase64: "AAEC", id: id) == nil, "short pairing key accepted")
expect(BLEFileLaneProtocol.deriveKey(pairingKeyBase64: pairingKey, id: "../etc") == nil, "unsafe transfer ID accepted")
expect(BLEFileLaneProtocol.deriveKey(pairingKeyBase64: pairingKey, id: UUID().uuidString) != nil, "Mac UUID rejected as an ID")

let preamble = BLEFileLaneProtocol.preamble(id: id)
expect(preamble.prefix(2) == Data([0, UInt8(("androp-lane:1:" + id).utf8.count)]), "preamble length prefix wrong")
expect(String(data: preamble.dropFirst(2), encoding: .utf8) == "androp-lane:1:" + id, "preamble text differs from Android")

expect(BLEFileLaneProtocol.fits(totalBytes: BLEFileLaneProtocol.maximumLaneBytes), "limit itself rejected")
expect(!BLEFileLaneProtocol.fits(totalBytes: BLEFileLaneProtocol.maximumLaneBytes + 1), "oversized selection accepted")
for bad in ["", ".", "..", ".hidden", "a/b", "a\\b", "a:b"] { expect(!BLEFileLaneProtocol.validName(bad), "unsafe name \(bad) accepted") }
expect(BLEFileLaneProtocol.validName("photo.jpg"), "ordinary name rejected")

print("BLE file lane protocol regressions: \(failures) failures")
exit(failures == 0 ? 0 : 1)
