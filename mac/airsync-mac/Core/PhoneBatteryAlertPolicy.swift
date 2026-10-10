import Foundation

/// Event-driven hysteresis: one alert until charging or recovery above the threshold.
enum PhoneBatteryAlertPolicy {
    static func nextLatch(level: Int, charging: Bool, threshold: Int, alerted: Bool) -> Bool? {
        guard (0...100).contains(level), (5...50).contains(threshold) else { return nil }
        if charging || level >= threshold + 5 { return false }
        return alerted
    }

    static func shouldAlert(level: Int, charging: Bool, threshold: Int, alerted: Bool, reported: Bool = true) -> Bool {
        guard reported else { return false }
        guard let latch = nextLatch(level: level, charging: charging, threshold: threshold, alerted: alerted) else { return false }
        return !charging && level <= threshold && !latch
    }
}
