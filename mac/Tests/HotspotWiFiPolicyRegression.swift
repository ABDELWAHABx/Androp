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
        print("Hotspot Wi-Fi policy: 13 checks passed")
    }
}
