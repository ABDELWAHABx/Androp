import Foundation
import AppKit
import Darwin
import CryptoKit

/// Runs the real app lifecycle in a disposable, uniquely identified app copy.
/// Three independent gates prevent an installed app from entering this mode.
enum LifecycleSelfTest {
    @MainActor private static var probeSession: URLSession?
    @MainActor private static var probeSocket: URLSessionWebSocketTask?
    nonisolated static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--self-test-lifecycle") &&
        ProcessInfo.processInfo.environment["ANDROP_LIFECYCLE_SELF_TEST"] == "1" &&
        Bundle.main.bundleIdentifier?.hasPrefix("app.androp.mac.lifecycle-test.") == true
    }

    @MainActor static func run() {
        guard isRequested else { return }
        let state = AppState.shared
        guard !state.isSyncPaused, state.device == nil, !state.isBLEEnabled,
              !state.keepAwakeEnabled, !state.experimentalClosedLidEnabled,
              !state.quickShareEnabled, !QuickShareManager.shared.isEnabled else {
            finish(success: false, message: "Isolated idle launch configuration is invalid")
            return
        }
        MacPowerManager.shared.start()
        print("LIFECYCLE launch: idle, radio-free, experimental power disabled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            finish(success: false, message: "Lifecycle self-test exceeded 15 seconds")
        }
        verifyBluetoothHandoff()
        pause(cycle: 1)
    }

    @MainActor private static func verifyBluetoothHandoff() {
        let state = AppState.shared
        let bluetooth = BLECentralManager.shared
        let phoneID = "lifecycle-test-phone"
        bluetooth.isManuallyDisconnected = false
        state.disconnectDevice(manual: false)
        guard !bluetooth.isManuallyDisconnected else {
            finish(success: false, message: "Network loss suppressed Bluetooth recovery")
            return
        }
        UserDefaults.standard.set(phoneID, forKey: "lastBLEPairedDeviceID")
        state.device = Device(name: "Test phone", ipAddress: "127.0.0.1", port: 0,
                              version: "1", adbPorts: [], deviceId: phoneID)
        bluetooth.connectingDeviceUUID = "lifecycle-test-radio"
        bluetooth.connectionStatus = .authenticated
        state.disconnectDevice(manual: false)
        guard state.device?.deviceId == phoneID, state.device?.isBLE == true,
              bluetooth.isAuthenticated, !state.isSyncPaused else {
            finish(success: false, message: "Network loss destroyed Bluetooth fallback")
            return
        }
        print("LIFECYCLE handoff: network loss retains authenticated Bluetooth and phone identity")
    }

    @MainActor private static func pause(cycle: Int) {
        // An idle production app normally has scanning status. Seed that public
        // state without opening the radio; teardown still executes the real
        // stopScanning/disconnect chain that previously overflowed the stack.
        BLECentralManager.shared.connectionStatus = .scanning
        AppState.shared.setSyncPaused(true)
        AppState.shared.setSyncPaused(true) // Repeated pause must be harmless.
        probeSocket?.cancel(with: .goingAway, reason: nil)
        probeSocket = nil
        probeSession?.invalidateAndCancel()
        probeSession = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let server = WebSocketServer.shared
            server.lock.lock()
            let stopped = !server.shouldRun && server.activeSessions.isEmpty && server.servers.isEmpty
            server.lock.unlock()
            guard AppState.shared.isSyncPaused, AppState.shared.device == nil,
                  BLECentralManager.shared.connectionStatus == .disconnected,
                  server.getListeningNetworkEndpoint() == nil,
                  !AppState.shared.hasActiveConnectionMonitoring, stopped,
                  !DiscoveryManager.shared.isServiceRunning, !QuickShareManager.shared.isRunning,
                  !MacPowerManager.shared.keepAwakeActive, !MacPowerManager.shared.closedLidOverrideActive else {
                finish(success: false, message: "Pause did not stop services in cycle \(cycle)")
                return
            }
            print("LIFECYCLE pause \(cycle): scanning teardown, timers, sockets, discovery and power stopped")
            if cycle == 3 {
                finish(success: true, message: "3 idle Pause cycles, 2 real Resume cycles; no recursion")
            } else {
                AppState.shared.setSyncPaused(false)
                AppState.shared.setSyncPaused(false) // Repeated resume must be harmless.
                awaitResume(cycle: cycle, deadline: ProcessInfo.processInfo.systemUptime + 4)
            }
        }
    }

    @MainActor private static func awaitResume(cycle: Int, deadline: TimeInterval) {
        let server = WebSocketServer.shared
        server.lock.lock()
        let listening = server.shouldRun && !server.servers.isEmpty
        server.lock.unlock()
        if listening, case .started = AppState.shared.webSocketStatus {
            guard !AppState.shared.isSyncPaused, DiscoveryManager.shared.isServiceRunning,
                  !MacPowerManager.shared.keepAwakeActive, !MacPowerManager.shared.closedLidOverrideActive else {
                finish(success: false, message: "Resume state is invalid in cycle \(cycle)")
                return
            }
            print("LIFECYCLE resume \(cycle): real WebSocket listener and discovery started")
            verifyIPv4Handshake(cycle: cycle)
        } else if ProcessInfo.processInfo.systemUptime >= deadline {
            finish(success: false, message: "Real listener did not resume within four seconds")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                awaitResume(cycle: cycle, deadline: deadline)
            }
        }
    }

    /// Exercise the advertised address family and encrypted pairing protocol,
    /// rather than trusting the listener's in-memory started flag.
    @MainActor private static func verifyIPv4Handshake(cycle: Int) {
        let server = WebSocketServer.shared
        guard let port = server.localPort,
              Int(port) == AppState.shared.myDevice?.port,
              let key = server.symmetricKey,
              let url = URL(string: "ws://127.0.0.1:\(port)/socket") else {
            finish(success: false, message: "Listener port does not match the configured pairing endpoint")
            return
        }
        if let endpoint = server.getListeningNetworkEndpoint(), endpoint.port != port {
            finish(success: false, message: "Discovery advertised a different port from the running listener")
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: url)
        probeSession = session
        probeSocket = socket
        socket.resume()
        Task { @MainActor in
            do {
                let device: [String: Any] = ["type": "device", "data": [
                    "id": "lifecycle-test-phone", "name": "Test phone", "ipAddress": "127.0.0.1",
                    "port": 6997, "version": "1", "adbPorts": [], "targetIpAddress": "127.0.0.1"
                ]]
                let json = String(data: try JSONSerialization.data(withJSONObject: device), encoding: .utf8)!
                guard let wrong = encryptMessage(json, using: SymmetricKey(size: .bits256)),
                      let valid = encryptMessage(json, using: key) else {
                    finish(success: false, message: "Unable to prepare encrypted handshake probe")
                    return
                }
                try await socket.send(.string(wrong))
                try await Task.sleep(nanoseconds: 100_000_000)
                guard server.authenticatedSessionIdentity == nil else {
                    finish(success: false, message: "Wrong-key WebSocket handshake was accepted")
                    return
                }
                try await socket.send(.string(valid))
                var receivedMacInfo = false
                for _ in 0..<8 {
                    let message = try await socket.receive()
                    guard case .string(let encrypted) = message,
                          let clear = decryptMessageToData(encrypted, using: key),
                          let payload = try JSONSerialization.jsonObject(with: clear) as? [String: Any] else { continue }
                    if payload["type"] as? String == "macInfo" { receivedMacInfo = true; break }
                }
                guard receivedMacInfo, server.authenticatedSessionIdentity != nil,
                      AppState.shared.device?.deviceId == "lifecycle-test-phone" else {
                    finish(success: false, message: "IPv4 WebSocket did not complete the encrypted device/macInfo handshake")
                    return
                }
                print("LIFECYCLE IPv4 handshake \(cycle): configured port reachable; wrong key rejected; encrypted macInfo received")
                if cycle == 1 {
                    AppState.shared.quickShareEnabled = true
                    awaitQuickShareToggle(deadline: ProcessInfo.processInfo.systemUptime + 3)
                } else {
                    pause(cycle: cycle + 1)
                }
            } catch {
                finish(success: false, message: "IPv4 pairing probe failed: \(error)")
            }
        }
    }

    @MainActor private static func awaitQuickShareToggle(deadline: TimeInterval) {
        let manager = QuickShareManager.shared
        if let port = NearbyConnectionManager.shared.readyQuickSharePort {
            guard (1...65535).contains(port), manager.isEnabled, manager.isRunning,
                  AppState.shared.quickShareEnabled, !AppState.shared.isSyncPaused,
                  persistedQuickShareEnabled == true else {
                finish(success: false, message: "Quick Share enable setting did not start the real listener")
                return
            }
            AppState.shared.quickShareEnabled = false
            guard !manager.isEnabled, !manager.isRunning,
                  NearbyConnectionManager.shared.readyQuickSharePort == nil,
                  persistedQuickShareEnabled == false else {
                finish(success: false, message: "Quick Share disable setting retained a listener or stale port")
                return
            }
            print("LIFECYCLE quickshare: settings enable starts a real listener; disable removes listener and advertised port")
            pause(cycle: 2)
        } else if ProcessInfo.processInfo.systemUptime >= deadline {
            finish(success: false, message: "Quick Share listener did not become ready after enabling settings")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                awaitQuickShareToggle(deadline: deadline)
            }
        }
    }

    /// Launch flags isolate initial state and intentionally outrank saved defaults.
    /// Inspect the actual application domain to verify Settings persistence.
    @MainActor private static var persistedQuickShareEnabled: Bool? {
        guard let domain = Bundle.main.bundleIdentifier else { return nil }
        return UserDefaults.standard.persistentDomain(forName: domain)?["quickShareEnabled"] as? Bool
    }

    @MainActor static func cleanUp() {
        guard isRequested else { return }
        AppState.shared.setSyncPaused(true)
        probeSocket?.cancel(with: .goingAway, reason: nil)
        probeSession?.invalidateAndCancel()
        DiscoveryManager.shared.stop()
        QuickShareManager.shared.suspendService()
        BLECentralManager.shared.disconnect(restartScanning: false)
        MacPowerManager.shared.stop()
        WebSocketServer.shared.stop()
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
    }

    @MainActor private static func finish(success: Bool, message: String) {
        cleanUp()
        print("LIFECYCLE \(success ? "PASS" : "FAIL"): \(message)")
        fflush(stdout)
        exit(success ? 0 : 1)
    }
}
