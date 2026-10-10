import Foundation
import Combine

// Compile the production manager against inert application/transport adapters.
struct HotspotTestDevice { let deviceId: String; var isBLE = false }
enum BLEConstants { static let charMediaControl = "control" }
final class BLECentralManager {
    static let shared = BLECentralManager()
    var isAuthenticated = false
    var connectingDeviceUUID: String?
    var messages: [[String: Any]] = []
    func writeChunked(characteristicUUID: String, payload: String) -> Bool {
        guard let bytes = payload.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let data = envelope["data"] as? [String: Any] else { return false }
        messages.append(data)
        return true
    }
}
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var device: HotspotTestDevice?
    @Published var isSyncPaused = false
}
final class WebSocketServer {
    static let shared = WebSocketServer()
    var accepts = true
    var messages: [[String: Any]] = []
    func sendPowerProtocol(type: String, data: [String: Any]) -> Bool {
        precondition(type == "phoneHotspotControl")
        if accepts { messages.append(data) }
        return accepts
    }
}

@main
struct PhoneHotspotManagerRegression {
    static func main() {
        let state = AppState.shared
        let transport = WebSocketServer.shared
        let manager = PhoneHotspotManager.shared
        manager.send(.enable)
        expect(transport.messages.isEmpty && manager.pendingAction == nil, "offline controls are inert")

        state.device = HotspotTestDevice(deviceId: "phone-a")
        drain()
        manager.send(.status)
        expect(manager.pendingAction == .status && transport.messages.count == 1, "status request awaits reply")
        let first = transport.messages.last!
        manager.send(.enable)
        expect(transport.messages.count == 1, "only one request may be pending")
        manager.handleState(reply(first, id: "wrong-id", status: "ready", enabled: true))
        expect(manager.state == nil && manager.pendingAction == .status, "unmatched ID ignored")
        manager.handleState(reply(first, action: "enable", status: "ready", enabled: true))
        expect(manager.state == nil, "unmatched action ignored")
        manager.handleState(reply(first, status: "ready", enabled: false))
        expect(manager.state?.hotspotEnabled == false && manager.pendingAction == nil, "actual observed disabled state accepted")

        manager.send(.enable)
        let enable = transport.messages.last!
        manager.handleState(reply(enable, status: "requesting", enabled: nil))
        expect(manager.pendingAction == .enable && manager.state?.hotspotEnabled == nil, "submitted request never means enabled")
        manager.handleState(reply(enable, status: "enabled", enabled: true))
        expect(manager.pendingAction == nil && manager.state?.hotspotEnabled == true, "confirmation ends request")

        manager.send(.disable)
        let obsolete = transport.messages.last!
        state.device = HotspotTestDevice(deviceId: "phone-b")
        drain()
        expect(manager.pendingAction == nil && manager.state == nil, "device change clears request and old phone state")
        manager.handleState(reply(obsolete, status: "disabled", enabled: false))
        expect(manager.state == nil, "late old-phone reply ignored")

        manager.send(.status)
        state.isSyncPaused = true
        drain()
        expect(manager.pendingAction == nil && manager.state == nil, "pause clears outstanding work")
        let count = transport.messages.count
        manager.send(.setup)
        expect(transport.messages.count == count, "pause prevents setup traffic")

        state.isSyncPaused = false
        drain()
        transport.accepts = false
        manager.send(.status)
        expect(manager.pendingAction == nil && manager.message != nil, "transport rejection leaves no stuck pending state")
        transport.accepts = true
        manager.send(.status)
        state.device = nil
        drain()
        expect(manager.pendingAction == nil && manager.message == nil, "disconnect clears status and timeout")
        var results: [String] = []
        let completion: (Bool?) -> Void = { value in results.append(value.map { $0 ? "on" : "off" } ?? "failed") }
        state.device = HotspotTestDevice(deviceId: "phone-c")
        drain()
        manager.send(.status, completion: completion)
        let statusRequest = transport.messages.last!
        manager.handleState(reply(statusRequest, status: "ready", enabled: false))
        expect(results == ["off"], "confirmed off is distinct from failed observation")
        manager.send(.enable, completion: completion)
        let activation = transport.messages.last!
        manager.handleState(reply(activation, status: "requesting", enabled: nil))
        expect(results == ["off"], "submission cannot start Wi-Fi joining")
        manager.handleState(reply(activation, status: "enabled", enabled: true))
        expect(results == ["off", "on"], "confirmed activation completes once")
        manager.handleState(reply(activation, status: "enabled", enabled: true))
        expect(results.count == 2, "duplicate confirmation cannot join twice")
        manager.send(.status, completion: completion)
        state.isSyncPaused = true
        drain()
        expect(results.last == "failed", "pause cancels completion without reporting hotspot off")
        state.isSyncPaused = false
        drain()
        transport.accepts = false
        manager.send(.status, completion: completion)
        expect(results.count == 4 && results.last == "failed", "transport failure cannot activate hotspot")
        transport.accepts = true
        manager.send(.status) { _ in manager.send(.enable) }
        manager.handleState(reply(transport.messages.last!, status: "ready", enabled: false))
        expect(manager.pendingAction == .enable, "completion can enqueue activation without old cleanup clearing it")
        manager.handleState(reply(transport.messages.last!, status: "enabled", enabled: true))
        let bluetooth = BLECentralManager.shared
        bluetooth.isAuthenticated = true
        bluetooth.connectingDeviceUUID = "ble-phone-c"
        manager.send(.enable, completion: completion)
        expect(bluetooth.messages.count == 1, "hotspot commands prefer existing authenticated BLE")
        let bleRequest = bluetooth.messages.last!
        state.device = nil
        drain()
        expect(manager.pendingAction == .enable, "temporary Wi-Fi loss preserves bound BLE activation")
        state.device = HotspotTestDevice(deviceId: "ble-phone-c", isBLE: true)
        drain()
        manager.handleState(reply(bleRequest, status: "enabled", enabled: true))
        expect(manager.pendingAction == nil && results.last == "on", "BLE handoff can confirm activation")
        manager.send(.status, completion: completion)
        let oldPeerRequest = bluetooth.messages.last!
        bluetooth.connectingDeviceUUID = "another-phone"
        manager.handleState(reply(oldPeerRequest, status: "ready", enabled: true))
        expect(manager.pendingAction == .status, "changed Bluetooth peer cannot complete old request")
        expect(!PhoneHotspotTransport.matches(deviceID: "phone-c", bluetoothPeer: "ble-phone-c"), "changed peer cannot trigger association")
        print("Phone hotspot manager: 26 checks passed")
    }

    private static func reply(_ request: [String: Any], id: String? = nil, action: String? = nil,
                              status: String, enabled: Bool?) -> [String: Any] {
        var result: [String: Any] = [
            "id": id ?? request["id"] as! String,
            "action": action ?? request["action"] as! String,
            "status": status, "message": "Phone response",
            "apiSupported": true, "writeSettingsGranted": true,
            "dataSaverEnabled": false, "canAttemptControl": true
        ]
        if let enabled { result["hotspotEnabled"] = enabled }
        return result
    }

    private static func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    private static func expect(_ value: Bool, _ label: String) { precondition(value, label) }
}
