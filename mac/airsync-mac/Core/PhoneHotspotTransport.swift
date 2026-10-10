import Foundation

enum PhoneHotspotTransport {
    static var bluetoothPeer: String? {
        BLECentralManager.shared.isAuthenticated ? BLECentralManager.shared.connectingDeviceUUID : nil
    }

    static func matches(deviceID: String, bluetoothPeer: String?) -> Bool {
        guard !AppState.shared.isSyncPaused else { return false }
        let device = AppState.shared.device
        if let bluetoothPeer {
            guard self.bluetoothPeer == bluetoothPeer else { return false }
            // Hotspot activation can remove the original Wi-Fi session. Keep
            // this request only while its authenticated Bluetooth peer remains.
            return device == nil || device?.isBLE == true || device?.deviceId == deviceID
        }
        return device?.deviceId == deviceID
    }

    static func send(_ data: [String: Any], bluetoothPeer: String?) -> Bool {
        if let bluetoothPeer {
            guard self.bluetoothPeer == bluetoothPeer,
                  let bytes = try? JSONSerialization.data(withJSONObject: ["type": "phoneHotspotControl", "data": data]),
                  let payload = String(data: bytes, encoding: .utf8) else { return false }
            return BLECentralManager.shared.writeChunked(characteristicUUID: BLEConstants.charMediaControl, payload: payload)
        }
        return WebSocketServer.shared.sendPowerProtocol(type: "phoneHotspotControl", data: data)
    }
}
