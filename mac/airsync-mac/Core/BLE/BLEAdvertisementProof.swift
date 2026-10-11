import Foundation
import CryptoKit

/// Verifies the phone's rotating advertisement proof. Android rotates its private
/// Bluetooth address, so the CoreBluetooth identifier of an already paired phone
/// changes over time. A valid proof shows the advertiser holds the pairing token
/// without the Mac revealing it first. Must match BleAdvertisementProof.kt.
enum BLEAdvertisementProof {
    static let manufacturerID: UInt16 = 0xFFFF
    static let proofBytes = 5
    static let windowSeconds: TimeInterval = 600

    static func window(at date: Date = Date()) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / windowSeconds))
    }

    static func proof(token: String, window: Int64) -> Data {
        let key = SymmetricKey(data: Data(token.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("androp-ble:\(window)".utf8), using: key)
        return Data(mac).prefix(proofBytes)
    }

    /// Manufacturer data is the little-endian company ID followed by the proof.
    /// Adjacent windows are accepted to tolerate clock skew between the devices.
    static func verifies(manufacturerData: Data?, token: String, now: Date = Date()) -> Bool {
        guard !token.isEmpty, let data = manufacturerData, data.count == 2 + proofBytes else { return false }
        let bytes = [UInt8](data)
        guard UInt16(bytes[0]) | (UInt16(bytes[1]) << 8) == manufacturerID else { return false }
        let presented = Data(bytes[2...])
        let current = window(at: now)
        return (current - 1...current + 1).contains { proof(token: token, window: $0) == presented }
    }
}
