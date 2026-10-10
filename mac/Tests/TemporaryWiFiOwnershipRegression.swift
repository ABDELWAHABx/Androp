import Foundation

@main
struct TemporaryWiFiOwnershipRegression {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        let first = UUID(), second = UUID()
        var ownership = TemporaryWiFiOwnership()

        ownership.begin(owner: first, ssid: "transfer", currentSSID: "home")
        expect(ownership.willAssociate(owner: first), "must claim before a blocking CoreWLAN call")
        let cancelledJoin = ownership.release(owner: first, currentSSID: "transfer", cancelled: false)
        expect(cancelledJoin == TemporaryWiFiOwnership.Release(disconnect: true, restoreSSID: "home"),
               "late association after Cancel retains the pre-join network for cleanup")
        expect(ownership.release(owner: first, currentSSID: "transfer", cancelled: false) == nil,
               "late completion cannot clean up the same request twice")

        ownership.begin(owner: first, ssid: "reused", currentSSID: "home")
        expect(ownership.willAssociate(owner: first), "first lease claims association")
        ownership.begin(owner: second, ssid: "reused", currentSSID: "reused")
        expect(ownership.release(owner: first, currentSSID: "reused", cancelled: false) == nil,
               "old cleanup must not disconnect a new lease that reuses the SSID")
        expect(ownership.release(owner: second, currentSSID: "reused", cancelled: false) ==
               TemporaryWiFiOwnership.Release(disconnect: true, restoreSSID: "home"), "adoption retains original restoration target")

        ownership.begin(owner: first, ssid: "transfer", currentSSID: "home")
        expect(ownership.willAssociate(owner: first), "paused transfer had submitted association")
        expect(ownership.release(owner: first, currentSSID: "transfer", cancelled: true) ==
               TemporaryWiFiOwnership.Release(disconnect: true, restoreSSID: nil), "Pause releases owned hotspot without restoration work")

        ownership.begin(owner: first, ssid: "transfer", currentSSID: "home")
        expect(ownership.willAssociate(owner: first), "user-switch scenario claims association")
        expect(ownership.release(owner: first, currentSSID: "office", cancelled: false) ==
               TemporaryWiFiOwnership.Release(disconnect: false, restoreSSID: nil), "never override a different network selected during transfer")

        ownership.begin(owner: first, ssid: "transfer", currentSSID: "home")
        expect(ownership.willAssociate(owner: first), "remote-stop scenario claims association")
        expect(ownership.release(owner: first, currentSSID: nil, cancelled: false) ==
               TemporaryWiFiOwnership.Release(disconnect: false, restoreSSID: "home"), "phone stop before cleanup still restores prior Wi-Fi")

        ownership.begin(owner: first, ssid: "transfer", currentSSID: "transfer")
        expect(ownership.release(owner: first, currentSSID: "transfer", cancelled: false) ==
               TemporaryWiFiOwnership.Release(disconnect: false, restoreSSID: nil), "already connected network was not created by this attempt")

        ownership.begin(owner: first, ssid: "transfer", currentSSID: "home")
        expect(!ownership.willAssociate(owner: second), "unrelated owner cannot authorize association")
        expect(ownership.release(owner: first, currentSSID: "home", cancelled: false) ==
               TemporaryWiFiOwnership.Release(disconnect: false, restoreSSID: nil), "scan failure does not disturb existing Wi-Fi")

        ownership.begin(owner: first, ssid: "transfer", currentSSID: nil)
        expect(ownership.willAssociate(owner: first), "offline Mac can own temporary association")
        expect(ownership.release(owner: first, currentSSID: "transfer", cancelled: false) ==
               TemporaryWiFiOwnership.Release(disconnect: true, restoreSSID: nil), "offline start has no restoration target")
        print("Temporary Wi-Fi ownership: \(checks) checks passed")
    }
}
