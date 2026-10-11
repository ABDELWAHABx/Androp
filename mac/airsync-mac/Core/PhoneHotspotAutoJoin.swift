import Foundation
import Combine
import CoreWLAN
import Network

/// Opt-in, like Instant Hotspot: when the Mac has had no network for a while and the phone is
/// still reachable (Bluetooth survives losing Wi-Fi), run the same Connect as the Hotspot row.
@MainActor
final class PhoneHotspotAutoJoin: ObservableObject {
    static let shared = PhoneHotspotAutoJoin()
    private static let defaultsKey = "autoJoinPhoneHotspot"
    /// While still offline, look again this often: the phone may come back over Bluetooth,
    /// or the cooldown after a failed attempt may end.
    private static let recheckInterval: TimeInterval = 30

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.defaultsKey)
            if isEnabled {
                // Find the hotspot among saved networks now, not when it is needed offline.
                HotspotWiFiConnector.shared.loadSavedNetworks()
                scheduleCheck(after: 0)
            } else {
                check?.cancel()
                check = nil
            }
        }
    }

    private let monitor = NWPathMonitor()
    private var offlineSince: Date?
    private var lastAttempt: Date?
    private var check: DispatchWorkItem?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async { self?.pathChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "app.androp.hotspot-auto-join", qos: .utility))
    }

    private func pathChanged(online: Bool) {
        if online {
            offlineSince = nil
            check?.cancel()
            check = nil
            return
        }
        if offlineSince == nil { offlineSince = Date() }
        if isEnabled { scheduleCheck(after: HotspotWiFiPolicy.autoJoinOfflineDelay) }
    }

    private func scheduleCheck(after delay: TimeInterval) {
        check?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        check = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func evaluate() {
        check = nil
        guard isEnabled, let offlineSince else { return }
        let connector = HotspotWiFiConnector.shared
        connector.selectPhone()
        let now = Date()
        let allowed = HotspotWiFiPolicy.shouldAutoJoin(
            enabled: isEnabled,
            offlineFor: now.timeIntervalSince(offlineSince),
            phoneReachable: AppState.shared.device != nil,
            busy: connector.isBusy || PhoneHotspotManager.shared.pendingAction != nil,
            paused: AppState.shared.isSyncPaused,
            manuallyDisconnected: UserDefaults.standard.isManuallyDisconnected,
            transferNetworkActive: TransferNetworkCoordinator.shared.isBusy,
            wifiPoweredOn: CWWiFiClient.shared().interface()?.powerOn() == true,
            hasHotspotName: HotspotWiFiPolicy.validSSID(connector.ssid),
            sinceLastAttempt: lastAttempt.map { now.timeIntervalSince($0) })
        guard allowed else {
            scheduleCheck(after: Self.recheckInterval)
            return
        }
        lastAttempt = now
        print("[hotspot] Mac is offline; joining the phone's hotspot automatically")
        connector.connect()
    }
}
