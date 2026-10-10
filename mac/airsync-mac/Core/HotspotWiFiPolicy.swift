import Foundation

nonisolated enum HotspotWiFiPolicy {
    static func validSSID(_ ssid: String) -> Bool {
        (1...32).contains(ssid.utf8.count) && !ssid.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func mayRetry(attempt: Int, elapsed: TimeInterval, cancelled: Bool) -> Bool {
        !cancelled && attempt >= 0 && attempt < 6 && elapsed.isFinite && elapsed >= 0 && elapsed < 30
    }
}

/// Cancellation wakes retry waits. A CoreWLAN call already submitted to macOS
/// cannot be undone safely; no subsequent scan, credential lookup or join starts.
nonisolated final class HotspotWiFiAttempt: @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelled = false
    var isCancelled: Bool {
        condition.lock(); defer { condition.unlock() }
        return cancelled
    }
    func cancel() {
        condition.lock(); cancelled = true; condition.broadcast(); condition.unlock()
    }
    func waitForRetry() {
        condition.lock(); defer { condition.unlock() }
        if !cancelled { _ = condition.wait(until: Date().addingTimeInterval(1.5)) }
    }
}
