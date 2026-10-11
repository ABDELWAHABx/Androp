import Foundation

/// Timing for keeping the phone link up. Must stay in step with BleLinkPolicy.kt.
enum BLELinkPolicy {
    /// After an authenticated link drops (or the Mac wakes), scan without resting for this long.
    /// The phone advertises faster for the same minute, so a phone in range returns in seconds.
    static let reconnectBurst: TimeInterval = 60
    static let burstRescanDelay: TimeInterval = 0.5

    /// The Mac pings the phone this often while authenticated; the phone answers with blePong.
    /// The phone drops a Mac it has not heard from in four minutes, so this must stay well below that.
    static let heartbeatInterval: TimeInterval = 20
    /// Pings sent with nothing at all received since. Three unanswered (checked on the next tick,
    /// about 80 seconds after the last data) means the link is dead.
    static let maximumMissedHeartbeats = 3

    static func inReconnectBurst(until: Date?, now: Date = Date()) -> Bool {
        guard let until else { return false }
        return now < until
    }

    /// Only a phone that has answered a ping can be judged silent: an older phone build
    /// never answers, and must not be disconnected every minute.
    static func linkIsDead(heartbeatSupported: Bool, missedHeartbeats: Int) -> Bool {
        heartbeatSupported && missedHeartbeats >= maximumMissedHeartbeats
    }

    static func pingPayload(id: Int) -> String? {
        guard let bytes = try? JSONSerialization.data(withJSONObject: ["type": "blePing", "data": ["id": id]]) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    static func isPong(_ payload: String) -> Bool {
        guard payload.utf8.count <= 256, let bytes = payload.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
        return message["type"] as? String == "blePong"
    }
}
