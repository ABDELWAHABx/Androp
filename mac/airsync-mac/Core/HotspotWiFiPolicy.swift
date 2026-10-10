import Foundation

nonisolated enum HotspotWiFiPolicy {
    static func validSSID(_ ssid: String) -> Bool {
        (1...32).contains(ssid.utf8.count) && !ssid.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func validLocalIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let bytes = parts.compactMap { part -> UInt8? in
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  part.count == 1 || !part.hasPrefix("0") else { return nil }
            return UInt8(part)
        }
        guard bytes.count == 4 else { return false }
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 192 && bytes[1] == 168)
    }

    static func mayRetry(attempt: Int, elapsed: TimeInterval, cancelled: Bool) -> Bool {
        !cancelled && attempt >= 0 && attempt < 6 && elapsed.isFinite && elapsed >= 0 && elapsed < 30
    }

    static func mayRecoverHandoff(status: String?, hasPhone: Bool, paused: Bool, manuallyDisconnected: Bool) -> Bool {
        status == "requesting" && !hasPhone && !paused && !manuallyDisconnected
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
