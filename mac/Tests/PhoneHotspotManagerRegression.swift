import Foundation
import Combine

// Compile the production manager against inert application/transport adapters.
struct HotspotTestDevice { let deviceId: String }
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
        print("Phone hotspot manager: 14 checks passed")
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
