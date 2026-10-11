import Foundation

/// Timing for keeping the phone link up. Must stay in step with BleLinkPolicy.kt.
enum BLELinkPolicy {
    /// After an authenticated link drops (or the Mac wakes), scan without resting for this long.
    /// The phone advertises faster for the same minute, so a phone in range returns in seconds.
    static let reconnectBurst: TimeInterval = 60
    static let burstRescanDelay: TimeInterval = 0.5

    /// The Mac pings the phone this often while authenticated; the phone answers with blePong.
    /// The phone drops a Mac it has not heard from in 160 seconds, so this must stay well below that.
    /// The Mac holds an App Nap exemption while authenticated, so the timer fires on time.
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

    /// After a declined or failed pairing prompt, wait a day before asking again.
    static let bondRetryInterval: TimeInterval = 24 * 60 * 60
    /// A pending connect that ends without connecting is re-armed after this rest.
    static let bondedReconnectRetry: TimeInterval = 2

    /// Ask the phone to bond only when the user opted in, this phone isn't already the
    /// bonded one, and no prompt was shown for it recently.
    static func mayProbeBond(enabled: Bool, bondedPeer: String?, peer: String,
                             lastAttemptPeer: String?, lastAttempt: Date?, now: Date = Date()) -> Bool {
        guard enabled, bondedPeer != peer else { return false }
        guard lastAttemptPeer == peer, let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= bondRetryInterval
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
