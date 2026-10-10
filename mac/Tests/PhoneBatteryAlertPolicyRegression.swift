import Foundation

@main
struct PhoneBatteryAlertPolicyRegression {
    static func main() {
        expect(PhoneBatteryAlertPolicy.shouldAlert(level: 20, charging: false, threshold: 20, alerted: false), "threshold crossing")
        expect(!PhoneBatteryAlertPolicy.shouldAlert(level: 15, charging: false, threshold: 20, alerted: true), "duplicate report/reconnect")
        expect(!PhoneBatteryAlertPolicy.shouldAlert(level: 5, charging: true, threshold: 20, alerted: false), "charging suppresses alert")
        expect(PhoneBatteryAlertPolicy.nextLatch(level: 15, charging: true, threshold: 20, alerted: true) == false, "charging resets cycle")
        expect(PhoneBatteryAlertPolicy.nextLatch(level: 24, charging: false, threshold: 20, alerted: true) == true, "hysteresis avoids chatter")
        expect(PhoneBatteryAlertPolicy.nextLatch(level: 25, charging: false, threshold: 20, alerted: true) == false, "recovery resets cycle")
        expect(!PhoneBatteryAlertPolicy.shouldAlert(level: -1, charging: false, threshold: 20, alerted: false), "invalid negative sample")
        expect(!PhoneBatteryAlertPolicy.shouldAlert(level: 101, charging: false, threshold: 20, alerted: false), "invalid oversized sample")
        expect(!PhoneBatteryAlertPolicy.shouldAlert(level: 10, charging: false, threshold: 200, alerted: false), "invalid setting")
        expect(!PhoneBatteryAlertPolicy.shouldAlert(level: 0, charging: false, threshold: 20, alerted: false, reported: false), "unknown BLE battery")
        print("Phone battery alert policy: 10 checks passed")
    }

    private static func expect(_ passed: Bool, _ label: String) {
        precondition(passed, "Failed: \(label)")
    }
}
