import Foundation

@main
struct HotspotWiFiPolicyRegression {
    static func main() {
        precondition(!HotspotWiFiPolicy.validSSID(""))
        precondition(HotspotWiFiPolicy.validSSID("Galaxy S21 FE"))
        precondition(HotspotWiFiPolicy.validSSID(String(repeating: "a", count: 32)))
        precondition(!HotspotWiFiPolicy.validSSID(String(repeating: "a", count: 33)))
        precondition(!HotspotWiFiPolicy.validSSID(String(repeating: "📱", count: 9)))
        precondition(!HotspotWiFiPolicy.validSSID("phone\nnetwork"))
        precondition(HotspotWiFiPolicy.validSSID(" Phone ")) // preserve meaningful SSID whitespace
        precondition(HotspotWiFiPolicy.mayRetry(attempt: 0, elapsed: 0, cancelled: false))
        precondition(!HotspotWiFiPolicy.mayRetry(attempt: 6, elapsed: 1, cancelled: false))
        precondition(!HotspotWiFiPolicy.mayRetry(attempt: 0, elapsed: 30, cancelled: false))
        precondition(!HotspotWiFiPolicy.mayRetry(attempt: 0, elapsed: .nan, cancelled: false))
        precondition(!HotspotWiFiPolicy.mayRetry(attempt: 0, elapsed: 1, cancelled: true))
        precondition(HotspotWiFiPolicy.mayRetry(attempt: 10, elapsed: 50, cancelled: false, maxAttempts: 40, window: 75))
        precondition(HotspotWiFiPolicy.likelyHotspot(phoneName: "Galaxy S21 FE", savedNetworks: ["Home", "Galaxy S21 FE"]) == "Galaxy S21 FE")
        precondition(HotspotWiFiPolicy.likelyHotspot(phoneName: "Ahmed's S21", savedNetworks: ["Home", "AndroidAP_1234"]) == "AndroidAP_1234")
        precondition(HotspotWiFiPolicy.likelyHotspot(phoneName: "Phone", savedNetworks: ["Home", "Office"]) == nil)
        let attempt = HotspotWiFiAttempt()
        attempt.cancel()
        let start = ProcessInfo.processInfo.systemUptime
        attempt.waitForRetry()
        precondition(attempt.isCancelled && ProcessInfo.processInfo.systemUptime - start < 0.5)
        precondition(HotspotWiFiPolicy.mayRecoverHandoff(status: "requesting", hasPhone: false, paused: false, manuallyDisconnected: false))
        precondition(!HotspotWiFiPolicy.mayRecoverHandoff(status: "failed", hasPhone: false, paused: false, manuallyDisconnected: false))
        precondition(!HotspotWiFiPolicy.mayRecoverHandoff(status: "requesting", hasPhone: true, paused: false, manuallyDisconnected: false))
        precondition(!HotspotWiFiPolicy.mayRecoverHandoff(status: "requesting", hasPhone: false, paused: true, manuallyDisconnected: false))
        func autoJoin(enabled: Bool = true, offlineFor: TimeInterval? = 15, phoneReachable: Bool = true, busy: Bool = false,
                      paused: Bool = false, manual: Bool = false, transfer: Bool = false, wifiOn: Bool = true,
                      named: Bool = true, since: TimeInterval? = nil) -> Bool {
            HotspotWiFiPolicy.shouldAutoJoin(enabled: enabled, offlineFor: offlineFor, phoneReachable: phoneReachable,
                busy: busy, paused: paused, manuallyDisconnected: manual, transferNetworkActive: transfer,
                wifiPoweredOn: wifiOn, hasHotspotName: named, sinceLastAttempt: since)
        }
        precondition(autoJoin())
        precondition(!autoJoin(enabled: false))
        precondition(!autoJoin(offlineFor: nil))
        precondition(!autoJoin(offlineFor: HotspotWiFiPolicy.autoJoinOfflineDelay - 1))
        precondition(!autoJoin(phoneReachable: false))
        precondition(!autoJoin(busy: true))
        precondition(!autoJoin(paused: true))
        precondition(!autoJoin(manual: true))
        precondition(!autoJoin(transfer: true))
        precondition(!autoJoin(wifiOn: false))
        precondition(!autoJoin(named: false))
        precondition(!autoJoin(since: 60))
        precondition(autoJoin(since: HotspotWiFiPolicy.autoJoinCooldown))
        precondition(!HotspotWiFiPolicy.mayRecoverHandoff(status: "requesting", hasPhone: false, paused: false, manuallyDisconnected: true))
        for value in ["192.168.43.2", "172.16.0.2", "172.31.255.2", "10.0.0.2"] {
            precondition(HotspotWiFiPolicy.validLocalIPv4(value))
        }
        for value in ["127.0.0.1", "8.8.8.8", "224.0.0.1", "172.32.0.1", "192.168.1.256", "192.168.01.1", "phone.local", "192.168.1.2:80", "::1", "169.254.1.1"] {
            precondition(!HotspotWiFiPolicy.validLocalIPv4(value))
        }
        print("Hotspot Wi-Fi policy: 32 checks passed")
    }
}
