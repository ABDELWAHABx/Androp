import Foundation
import Combine
import Darwin

struct RegressionFailure: Error, CustomStringConvertible {
    let description: String
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw RegressionFailure(description: message) }
}
func makeManager() -> BLECentralManager {
    AppState.shared.device = nil
    AppState.shared.isBLEEnabled = true
    AppState.shared.isBLEAutoConnectEnabled = true
    AppState.shared.isSyncPaused = false
    return BLECentralManager(testingWithoutRadio: true)
}
func makeDevice(_ address: String) -> Device {
    Device(name: "Phone", ipAddress: address, port: 1234, version: "1", adbPorts: [], deviceId: "phone")
}

// The semaphore publishes the worker's result; the production method must
// reject before accessing main-thread state, without scheduling hidden work.
final class BackgroundWriteProbe: @unchecked Sendable {
    let manager: BLECentralManager
    let finished = DispatchSemaphore(value: 0)
    var accepted = true
    init(_ manager: BLECentralManager) { self.manager = manager }
}

let cases: [(String, () throws -> Void)] = [
    ("Off-main BLE writes reject synchronously without waiting on main", {
        let probe = BackgroundWriteProbe(makeManager())
        Thread.detachNewThread {
            probe.accepted = probe.manager.writeChunked(characteristicUUID: BLEConstants.charClipboardDataWrite, payload: "private clipboard")
            probe.finished.signal()
        }
        try expect(probe.finished.wait(timeout: .now() + 2) == .success, "off-main write blocked waiting for main")
        try expect(!probe.accepted, "off-main write reported success before checking its queue")
    }),
    ("Existing Android battery JSON remains compatible and placeholders remain unknown", {
        let oldWirePacket = Data(#"{"level":0,"isCharging":false}"#.utf8)
        let reported = try JSONDecoder().decode(DeviceStatus.Battery.self, from: oldWirePacket)
        try expect(reported.level == 0 && reported.isReported != false, "real wire zero became unknown")
        let placeholder = DeviceStatus.Battery(level: 0, isCharging: false, isReported: false)
        let encoded = try JSONEncoder().encode(placeholder)
        let decoded = try JSONDecoder().decode(DeviceStatus.Battery.self, from: encoded)
        try expect(decoded.isReported == false, "synthetic zero lost its unknown marker")
    }),
    ("Battery packets reject missing and invalid percentages while accepting real zero", {
        try expect(BLEConstants.batteryLevel(from: Data()) == nil, "empty packet became zero")
        try expect(BLEConstants.batteryLevel(from: Data([0, 1])) == nil, "extended packet was accepted")
        try expect(BLEConstants.batteryLevel(from: Data([101])) == nil, "101% packet was accepted")
        try expect(BLEConstants.batteryLevel(from: Data([255])) == nil, "255% packet was accepted")
        try expect(BLEConstants.batteryLevel(from: Data([0])) == 0, "real zero report was rejected")
        try expect(BLEConstants.batteryLevel(from: Data([100])) == 100, "full battery was rejected")
    }),
    ("Pause while scanning without a connected phone returns", {
        let manager = makeManager()
        manager.connectionStatus = .scanning
        AppState.shared.isSyncPaused = true
        manager.disconnect()
        try expect(manager.connectionStatus == .disconnected, "scanning pause left an active status")
        try expect(manager.isManuallyDisconnected, "pause did not suppress reconnection")
    }),
    ("Repeated idle and scanning teardown is idempotent", {
        let manager = makeManager()
        for _ in 0..<1000 {
            manager.stopScanning()
            manager.disconnect()
            manager.connectionStatus = .scanning
            manager.disconnect()
        }
        try expect(manager.connectionStatus == .disconnected, "repeated teardown did not finish")
        try expect(manager.connectingDeviceUUID == nil && manager.connectedDeviceName == nil,
                   "repeated teardown retained connection metadata")
    }),
    ("Stopping discovery preserves established connections", {
        let manager = makeManager()
        for status in [BLECentralManager.BLEConnectionStatus.connected, .authenticated] {
            manager.connectionStatus = status
            manager.stopScanning()
            try expect(manager.connectionStatus == status, "scan stopping disconnected a transport")
        }
        try expect(!manager.isManuallyDisconnected, "scan stopping set manual disconnect")
    }),
    ("Disconnect clears BLE device but preserves Wi-Fi device", {
        let manager = makeManager()
        AppState.shared.device = makeDevice("BLE")
        manager.connectionStatus = .authenticated
        manager.connectedDeviceName = "Phone"
        manager.disconnect()
        try expect(AppState.shared.device == nil, "BLE device survived teardown")
        try expect(manager.connectedDeviceName == nil, "connected name survived teardown")
        AppState.shared.device = makeDevice("192.168.1.2")
        manager.disconnect()
        try expect(AppState.shared.device?.ipAddress == "192.168.1.2", "BLE teardown deleted Wi-Fi device")
    }),
    ("Stop scan and Pause cancel pending reconnect work", {
        let manager = makeManager()
        manager.scheduleScanRestartForTesting(after: 30)
        try expect(manager.hasPendingScanRestartForTesting, "retry was never scheduled")
        manager.stopScanning()
        try expect(!manager.hasPendingScanRestartForTesting, "scan stopping retained retry")
        manager.scheduleScanRestartForTesting(after: 30)
        AppState.shared.isSyncPaused = true
        manager.disconnect()
        try expect(!manager.hasPendingScanRestartForTesting, "pause retained retry")
    }),
    ("Paused, disabled and manually disconnected states reject retries", {
        let manager = makeManager()
        AppState.shared.isSyncPaused = true
        manager.scheduleScanRestartForTesting(after: 30)
        try expect(!manager.hasPendingScanRestartForTesting, "paused state queued a retry")
        AppState.shared.isSyncPaused = false
        AppState.shared.isBLEEnabled = false
        manager.scheduleScanRestartForTesting(after: 30)
        try expect(!manager.hasPendingScanRestartForTesting, "disabled BLE queued a retry")
        AppState.shared.isBLEEnabled = true
        manager.isManuallyDisconnected = true
        manager.scheduleScanRestartForTesting(after: 30)
        try expect(!manager.hasPendingScanRestartForTesting, "manual disconnect queued a retry")
        manager.isManuallyDisconnected = false
        AppState.shared.isBLEAutoConnectEnabled = false
        manager.scheduleScanRestartForTesting(after: 30)
        try expect(!manager.hasPendingScanRestartForTesting, "disabled autoconnect queued a retry")
    }),
    ("Retry checks Pause again when it fires", {
        let manager = makeManager()
        manager.scheduleScanRestartForTesting(after: 0.01)
        AppState.shared.isSyncPaused = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try expect(!manager.hasPendingScanRestartForTesting, "fired retry retained its work item")
        try expect(manager.connectionStatus == .disconnected, "queued retry restarted after pause")
        manager.disconnect(restartScanning: true)
        try expect(manager.connectionStatus == .disconnected, "explicit restart scanned during pause")
    }),
    ("Published teardown callbacks cannot reenter disconnect", {
        let manager = makeManager()
        manager.connectionStatus = .scanning
        let observation = manager.$connectionStatus.dropFirst().sink { status in
            if status == .disconnected { manager.disconnect() }
        }
        manager.disconnect()
        withExtendedLifetime(observation) {}
        try expect(manager.connectionStatus == .disconnected, "reentrant teardown did not finish")
        try expect(manager.sessionGeneration == 1, "reentrant teardown reset the session twice")
    })
]

var failures = 0
for (name, test) in cases {
    do { try test(); print("PASS: \(name)") }
    catch { failures += 1; fputs("FAIL: \(name): \(error)\n", stderr) }
}
print("BLE lifecycle regressions: \(cases.count) tests, \(failures) failures")
exit(failures == 0 ? 0 : 1)
