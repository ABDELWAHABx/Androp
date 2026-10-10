import Foundation
import AppKit
import Darwin

/// Runs the real app lifecycle in a disposable, uniquely identified app copy.
/// Three independent gates prevent an installed app from entering this mode.
enum LifecycleSelfTest {
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
              !QuickShareManager.shared.isEnabled else {
            finish(success: false, message: "Isolated idle launch configuration is invalid")
            return
        }
        MacPowerManager.shared.start()
        print("LIFECYCLE launch: idle, radio-free, experimental power disabled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            finish(success: false, message: "Lifecycle self-test exceeded 15 seconds")
        }
        pause(cycle: 1)
    }

    @MainActor private static func pause(cycle: Int) {
        // An idle production app normally has scanning status. Seed that public
        // state without opening the radio; teardown still executes the real
        // stopScanning/disconnect chain that previously overflowed the stack.
        BLECentralManager.shared.connectionStatus = .scanning
        AppState.shared.setSyncPaused(true)
        AppState.shared.setSyncPaused(true) // Repeated pause must be harmless.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let server = WebSocketServer.shared
            server.lock.lock()
            let stopped = !server.shouldRun && server.activeSessions.isEmpty && server.servers.isEmpty
            server.lock.unlock()
            guard AppState.shared.isSyncPaused, AppState.shared.device == nil,
                  BLECentralManager.shared.connectionStatus == .disconnected,
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
            pause(cycle: cycle + 1)
        } else if ProcessInfo.processInfo.systemUptime >= deadline {
            finish(success: false, message: "Real listener did not resume within four seconds")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                awaitResume(cycle: cycle, deadline: deadline)
            }
        }
    }

    @MainActor static func cleanUp() {
        guard isRequested else { return }
        AppState.shared.setSyncPaused(true)
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
