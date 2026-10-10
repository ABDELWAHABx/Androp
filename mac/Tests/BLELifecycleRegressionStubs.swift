// Deliberately replace only application dependencies. The radio lifecycle and
// teardown methods under test are compiled from the production manager.
import Foundation
import Combine
import CoreBluetooth

enum LifecycleSelfTest { static let isRequested = false }

final class AppState {
    static let shared = AppState()
    @Published var device: Device?
    var status: DeviceStatus?
    var isBLEEnabled = true
    var isBLEAutoConnectEnabled = true
    var isSyncPaused = false
    static func getPreferredDeviceName(fallback: String?) -> String { fallback ?? "Phone" }
}

struct Device {
    var name: String
    var ipAddress: String
    var port: Int
    var version: String
    var adbPorts: [Int]
    var deviceId: String
    var isBLE: Bool { ipAddress == "BLE" || ipAddress == "Bluetooth LE" }
}
struct DiscoveredDevice {
    var deviceId: String
    var name: String
    var ips: [String]
    var port: Int
    var type: String
    var lastSeen: Date
}
final class WebSocketServer {
    static let shared = WebSocketServer()
    func sendMacStatusOverBLE() {}
}
final class MacInfoSyncManager {
    static let shared = MacInfoSyncManager()
    func forceRefresh() {}
}
final class BLETransportBridge {
    static let shared = BLETransportBridge()
    func handleIncoming(uuid: CBUUID, payload: String) {}
}
