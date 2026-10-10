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
        let attempt = HotspotWiFiAttempt()
        attempt.cancel()
        let start = ProcessInfo.processInfo.systemUptime
        attempt.waitForRetry()
        precondition(attempt.isCancelled && ProcessInfo.processInfo.systemUptime - start < 0.5)
        precondition(HotspotWiFiPolicy.mayRecoverHandoff(status: "requesting", hasPhone: false, paused: false, manuallyDisconnected: false))
        precondition(!HotspotWiFiPolicy.mayRecoverHandoff(status: "failed", hasPhone: false, paused: false, manuallyDisconnected: false))
        precondition(!HotspotWiFiPolicy.mayRecoverHandoff(status: "requesting", hasPhone: true, paused: false, manuallyDisconnected: false))
        precondition(!HotspotWiFiPolicy.mayRecoverHandoff(status: "requesting", hasPhone: false, paused: true, manuallyDisconnected: false))
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
