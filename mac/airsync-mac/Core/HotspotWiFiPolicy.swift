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

    static func mayRetry(attempt: Int, elapsed: TimeInterval, cancelled: Bool,
                         maxAttempts: Int = 6, window: TimeInterval = 30) -> Bool {
        !cancelled && attempt >= 0 && attempt < maxAttempts && elapsed.isFinite && elapsed >= 0 && elapsed < window
    }

    /// Pick the saved network most likely to be this phone's hotspot, so the
    /// common case needs no setup: exact name, then name containment, then the
    /// usual Android/Samsung/Pixel default hotspot names.
    static func likelyHotspot(phoneName: String?, savedNetworks: [String]) -> String? {
        let phone = (phoneName ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        if !phone.isEmpty {
            if let exact = savedNetworks.first(where: { $0.lowercased() == phone }) { return exact }
            if let partial = savedNetworks.first(where: {
                let name = $0.lowercased()
                return name.contains(phone)
            }) { return partial }
        }
        let defaults = ["androidap", "galaxy", "pixel", "oneplus", "xiaomi", "redmi", "moto", "nothing"]
        let candidates = savedNetworks.filter { name in defaults.contains { name.lowercased().hasPrefix($0) } }
        return candidates.count == 1 ? candidates[0] : nil
    }

    static func mayRecoverHandoff(status: String?, hasPhone: Bool, paused: Bool, manuallyDisconnected: Bool) -> Bool {
        status == "requesting" && !hasPhone && !paused && !manuallyDisconnected
    }

    /// Losing Wi-Fi for a moment (roaming, a router restart) must not start the hotspot.
    static let autoJoinOfflineDelay: TimeInterval = 10
    /// One automatic attempt per five minutes, whatever its outcome.
    static let autoJoinCooldown: TimeInterval = 300

    /// Joins the phone's hotspot by itself only when the user opted in and the Mac has had no
    /// network for a while. Never while paused or disconnected on purpose, while Connect is
    /// already running, during the local-only transfer network (no internet by design), or
    /// when Mac Wi-Fi is off, since that is usually deliberate.
    static func shouldAutoJoin(enabled: Bool, offlineFor: TimeInterval?, phoneReachable: Bool, busy: Bool,
                               paused: Bool, manuallyDisconnected: Bool, transferNetworkActive: Bool,
                               wifiPoweredOn: Bool, hasHotspotName: Bool, sinceLastAttempt: TimeInterval?) -> Bool {
        guard enabled, let offlineFor, offlineFor >= autoJoinOfflineDelay, phoneReachable, !busy, !paused,
              !manuallyDisconnected, !transferNetworkActive, wifiPoweredOn, hasHotspotName else { return false }
        return sinceLastAttempt.map { $0 >= autoJoinCooldown } ?? true
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
