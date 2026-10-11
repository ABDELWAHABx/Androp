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
    UserDefaults.standard.set("test-pairing-token", forKey: "bleAuthToken")
    UserDefaults.standard.set(false, forKey: "isManuallyDisconnected")
    UserDefaults.standard.removeObject(forKey: "bleAuthenticatedPeerUUID")
    UserDefaults.standard.removeObject(forKey: "bleAuthenticatedTokenFingerprint")
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
    ("Explicit QR permits first BLE contact without a previous Wi-Fi credential", {
        let manager = makeManager()
        let key = Data(repeating: 7, count: 32)
        UserDefaults.standard.removeObject(forKey: "bleAuthToken")
        UserDefaults.standard.set(key.base64EncodedString(), forKey: "encryptionKey")
        AppState.shared.isBLEAutoConnectEnabled = false
        try expect(manager.beginQRPairing(id: UUID(), key: key), "QR pairing window was rejected")
        try expect(manager.automaticConnectionAllowedForTesting, "first BLE pair incorrectly required Wi-Fi")
        try expect(manager.mayAutomaticallyConnectForTesting(to: "new-phone"), "new candidate was incorrectly pinned to old phone")
        manager.endQRPairing()
        try expect(!manager.hasQRPairingWindowForTesting && !manager.automaticConnectionAllowedForTesting,
                   "closing QR left unpaired scanning authorized")
    }),
    ("Pause and key replacement invalidate QR pairing authorization", {
        let manager = makeManager()
        let key = Data(repeating: 8, count: 32)
        UserDefaults.standard.set(key.base64EncodedString(), forKey: "encryptionKey")
        try expect(manager.beginQRPairing(id: UUID(), key: key), "QR pairing window was rejected")
        UserDefaults.standard.set(Data(repeating: 9, count: 32).base64EncodedString(), forKey: "encryptionKey")
        try expect(!manager.hasQRPairingWindowForTesting, "old key retained pairing authorization")
        AppState.shared.isSyncPaused = true
        manager.disconnect()
        try expect(!manager.hasQRPairingWindowForTesting, "pause retained the pairing window")
        try expect(!manager.beginQRPairing(id: UUID(), key: key), "paused app started QR pairing")
    }),
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
    ("Wi-Fi keeps automatic BLE discovery eligible", {
        let manager = makeManager()
        AppState.shared.device = makeDevice("192.168.1.2")
        try expect(manager.automaticConnectionAllowedForTesting, "Wi-Fi blocked BLE policy")
        manager.scheduleScanRestartForTesting(after: 30)
        try expect(manager.hasPendingScanRestartForTesting, "Wi-Fi prevented BLE retry")
        manager.ensureAutomaticConnection()
        try expect(manager.scheduledScanDelayForTesting == 30, "Wi-Fi lifecycle event shortened cooldown")
        manager.stopScanning()
    }),
    ("An authenticated BLE standby survives Wi-Fi discovery requests", {
        let manager = makeManager()
        manager.connectionStatus = .authenticated
        manager.connectingDeviceUUID = "authenticated-peer"
        AppState.shared.device = makeDevice("192.168.1.2")
        manager.ensureAutomaticConnection()
        manager.stopScanning()
        try expect(manager.isAuthenticated, "Wi-Fi request dropped authenticated BLE")
        try expect(manager.connectingDeviceUUID == "authenticated-peer", "authenticated peer identity was cleared")
        try expect(!manager.hasPendingScanRestartForTesting, "authenticated session scheduled discovery")
    }),
    ("Global manual disconnect and missing pairing suppress background discovery", {
        let manager = makeManager()
        UserDefaults.standard.set(true, forKey: "isManuallyDisconnected")
        manager.scheduleScanRestartForTesting(after: 30)
        try expect(!manager.hasPendingScanRestartForTesting, "global manual disconnect was ignored")
        UserDefaults.standard.set(false, forKey: "isManuallyDisconnected")
        UserDefaults.standard.removeObject(forKey: "bleAuthToken")
        manager.scheduleScanRestartForTesting(after: 30)
        try expect(!manager.hasPendingScanRestartForTesting, "unpaired app scheduled recurring discovery")
    }),
    ("Discovery windows stop scanning and back off to a bounded one-minute rest", {
        let manager = makeManager()
        for index in 0..<20 {
            manager.connectionStatus = .scanning
            manager.finishDiscoveryWindowForTesting()
            try expect(manager.connectionStatus == .disconnected, "window left continuous scanning active")
            try expect(manager.hasPendingScanRestartForTesting, "window did not arrange future discovery")
            let delay = manager.scheduledScanDelayForTesting ?? 0
            try expect(delay >= 5 && delay <= 30, "scan rest escaped its battery/availability bounds")
            if index >= 4 { try expect(delay == 30, "repeated missed discovery did not back off") }
        }
        manager.disconnect()
        try expect(!manager.hasPendingScanRestartForTesting, "manual stop retained discovery window")
    }),
    ("A discovery window never tears down an established connection", {
        let manager = makeManager()
        manager.connectionStatus = .authenticated
        manager.finishDiscoveryWindowForTesting()
        try expect(manager.isAuthenticated, "expired window disconnected a live link")
        try expect(!manager.hasPendingScanRestartForTesting, "live link retained periodic scan work")
    }),
    ("Transient connection and authentication timeout retries preserve intent and back off", {
        let manager = makeManager()
        AppState.shared.device = makeDevice("192.168.1.2")
        for index in 0..<20 {
            manager.retryTransportFailureForTesting()
            try expect(!manager.isManuallyDisconnected, "transient failure was treated as user disconnect")
            let delay = manager.scheduledScanDelayForTesting ?? 0
            try expect(delay >= 3 && delay <= 30, "transport retries escaped their bounds")
            if index >= 5 { try expect(delay == 30, "failing transport did not back off") }
        }
        try expect(AppState.shared.device?.ipAddress == "192.168.1.2", "BLE failure destroyed Wi-Fi")
        manager.disconnect()
    }),
    ("Authenticated peer pin prevents token probing of different BLE advertisers", {
        let manager = makeManager()
        manager.rememberPeerForTesting("paired-peer")
        try expect(manager.mayAutomaticallyConnectForTesting(to: "paired-peer"), "saved peer was rejected")
        try expect(!manager.mayAutomaticallyConnectForTesting(to: "other-peer"), "existing token could be sent to another advertiser")
        try expect(UserDefaults.standard.string(forKey: "bleAuthenticatedTokenFingerprint") != "test-pairing-token", "pin persisted a duplicate bearer token")
        UserDefaults.standard.set("new-pairing-token", forKey: "bleAuthToken")
        try expect(manager.mayAutomaticallyConnectForTesting(to: "new-peer"), "explicit new pairing retained old peer pin")
    }),
    ("Rejected authentication cools down that peer without blocking another phone", {
        let manager = makeManager()
        manager.rejectAuthenticationForTesting(peerUUID: "rejected-peer")
        try expect(!manager.isManuallyDisconnected, "auth rejection changed manual user intent")
        try expect(!manager.mayAutomaticallyConnectForTesting(to: "rejected-peer"), "rejected peer can immediately loop authentication")
        try expect(manager.mayAutomaticallyConnectForTesting(to: "different-peer"), "one bad advertiser blocked every phone")
        try expect(manager.mayAutomaticallyConnectForTesting(to: "rejected-peer", now: Date().addingTimeInterval(301)), "auth cooldown never expires")
        manager.disconnect()
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
    }),
    ("Visible QR pairing rests briefly between discovery windows instead of backing off", {
        let manager = makeManager()
        let key = Data(repeating: 6, count: 32)
        UserDefaults.standard.set(key.base64EncodedString(), forKey: "encryptionKey")
        try expect(manager.beginQRPairing(id: UUID(), key: key), "QR pairing window was rejected")
        for _ in 0..<6 {
            manager.connectionStatus = .scanning
            manager.finishDiscoveryWindowForTesting()
            try expect(manager.hasPendingScanRestartForTesting, "QR window did not arrange rescanning")
            try expect(manager.scheduledScanDelayForTesting == 1, "QR window backed off while the code was visible")
        }
        manager.endQRPairing()
    }),
    ("A lost link rescans almost at once during the reconnect burst, then backs off as before", {
        let manager = makeManager()
        manager.beginReconnectBurst()
        try expect(manager.reconnectBurstActiveForTesting, "reconnect burst did not start")
        for _ in 0..<5 {
            manager.retryTransportFailureForTesting()
            try expect(manager.scheduledScanDelayForTesting == BLELinkPolicy.burstRescanDelay, "failed reconnect rested during the burst")
            manager.connectionStatus = .scanning
            manager.finishDiscoveryWindowForTesting()
            try expect(manager.scheduledScanDelayForTesting == BLELinkPolicy.burstRescanDelay, "missed discovery rested during the burst")
        }
        manager.endReconnectBurstForTesting()
        manager.connectionStatus = .scanning
        manager.finishDiscoveryWindowForTesting()
        try expect((manager.scheduledScanDelayForTesting ?? 0) >= 5, "discovery kept scanning after the burst ended")
        manager.disconnect()
    }),
    ("Manual disconnect and pause end the reconnect burst", {
        let manager = makeManager()
        manager.beginReconnectBurst()
        manager.disconnect()
        try expect(!manager.reconnectBurstActiveForTesting, "manual disconnect kept rescanning")
        try expect(!manager.hasPendingScanRestartForTesting, "manual disconnect left a rescan queued")
        let paused = makeManager()
        paused.beginReconnectBurst()
        AppState.shared.isSyncPaused = true
        paused.retryTransportFailureForTesting()
        try expect(!paused.hasPendingScanRestartForTesting, "burst rescanned while paused")
        AppState.shared.isSyncPaused = false
    }),
    ("Heartbeat only judges a phone that answers pings, and fits inside the phone's own limit", {
        try expect(!BLELinkPolicy.linkIsDead(heartbeatSupported: false, missedHeartbeats: 1_000), "older phone build would be dropped every minute")
        try expect(!BLELinkPolicy.linkIsDead(heartbeatSupported: true, missedHeartbeats: BLELinkPolicy.maximumMissedHeartbeats - 1), "link dropped too eagerly")
        try expect(BLELinkPolicy.linkIsDead(heartbeatSupported: true, missedHeartbeats: BLELinkPolicy.maximumMissedHeartbeats), "dead link was kept")
        try expect(BLELinkPolicy.isPong(#"{"type":"blePong","data":{"id":4}}"#), "pong was not recognised")
        try expect(!BLELinkPolicy.isPong(#"{"type":"status","data":{}}"#), "ordinary control message was taken for a pong")
        let ping = BLELinkPolicy.pingPayload(id: 7) ?? ""
        let decoded = (try? JSONSerialization.jsonObject(with: Data(ping.utf8))) as? [String: Any]
        try expect(decoded?["type"] as? String == "blePing", "ping envelope type changed")
        // BleLinkPolicy.kt PEER_SILENCE_LIMIT_MS is 160 s; the Mac must reconnect well before it.
        try expect(BLELinkPolicy.heartbeatInterval * Double(BLELinkPolicy.maximumMissedHeartbeats + 1) * 2 <= 160,
                   "phone could drop a Mac that is still pinging")
    }),
    ("Instant reconnect asks to pair only when opted in, once per phone per day", {
        let now = Date()
        try expect(!BLELinkPolicy.mayProbeBond(enabled: false, bondedPeer: nil, peer: "A", lastAttemptPeer: nil, lastAttempt: nil, now: now),
                   "paired without the user opting in")
        try expect(BLELinkPolicy.mayProbeBond(enabled: true, bondedPeer: nil, peer: "A", lastAttemptPeer: nil, lastAttempt: nil, now: now),
                   "opted-in phone was never asked")
        try expect(!BLELinkPolicy.mayProbeBond(enabled: true, bondedPeer: "A", peer: "A", lastAttemptPeer: nil, lastAttempt: nil, now: now),
                   "already bonded phone was asked again")
        try expect(!BLELinkPolicy.mayProbeBond(enabled: true, bondedPeer: nil, peer: "A", lastAttemptPeer: "A",
                                              lastAttempt: now.addingTimeInterval(-60), now: now), "declined prompt repeated within a day")
        try expect(BLELinkPolicy.mayProbeBond(enabled: true, bondedPeer: nil, peer: "B", lastAttemptPeer: "A",
                                             lastAttempt: now.addingTimeInterval(-60), now: now), "another phone inherited a decline")
        try expect(BLELinkPolicy.mayProbeBond(enabled: true, bondedPeer: nil, peer: "A", lastAttemptPeer: "A",
                                             lastAttempt: now.addingTimeInterval(-BLELinkPolicy.bondRetryInterval), now: now), "decline never expired")
    }),
    ("Instant reconnect stays off without a radio and never blocks scanning", {
        let manager = makeManager()
        UserDefaults.standard.set(UUID().uuidString, forKey: "bleBondedPeerUUID")
        manager.instantReconnectEnabled = true
        manager.ensureAutomaticConnection()
        manager.retryTransportFailureForTesting()
        try expect(manager.hasPendingScanRestartForTesting, "bonded reconnect replaced discovery")
        try expect(!manager.fileLaneAvailable, "file lane offered without an authenticated phone")
        manager.instantReconnectEnabled = false
        UserDefaults.standard.removeObject(forKey: "bleBondedPeerUUID")
        manager.disconnect()
    })
]

let preferenceKeys = ["bleAuthToken", "isManuallyDisconnected", "bleAuthenticatedPeerUUID", "bleAuthenticatedTokenFingerprint",
                      "bleInstantReconnect", "bleBondedPeerUUID"]
let savedPreferences = preferenceKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
var failures = 0
for (name, test) in cases {
    do { try test(); print("PASS: \(name)") }
    catch { failures += 1; fputs("FAIL: \(name): \(error)\n", stderr) }
}
for (key, value) in savedPreferences {
    if let value = value { UserDefaults.standard.set(value, forKey: key) }
    else { UserDefaults.standard.removeObject(forKey: key) }
}
print("BLE lifecycle regressions: \(cases.count) tests, \(failures) failures")
exit(failures == 0 ? 0 : 1)
