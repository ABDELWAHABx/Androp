import Foundation

/// Bounds BLE control traffic without losing parameters or allocating artwork frames.
enum BLEControlPolicy {
    static let maximumBytes = 64 * 1024
    static func envelope(type: String, data: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(data),
              let bytes = try? JSONSerialization.data(withJSONObject: ["type": type, "data": data]),
              bytes.count <= maximumBytes else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
    static func compactStatus(_ data: [String: Any]) -> [String: Any] {
        var compact: [String: Any] = [:]
        for key in ["battery", "isPaired"] { compact[key] = data[key] }
        if let music = data["music"] as? [String: Any] {
            var small: [String: Any] = [:]
            for key in ["isPlaying", "volume", "isMuted", "likeStatus", "elapsedTime", "duration", "timestamp", "playbackRate"] {
                small[key] = music[key]
            }
            small["title"] = String((music["title"] as? String ?? "").prefix(512))
            small["artist"] = String((music["artist"] as? String ?? "").prefix(512))
            // Explicitly clear stale artwork from a previous Wi-Fi session.
            small["albumArt"] = ""
            compact["music"] = small
        }
        return compact
    }
    static func clipboardRetryDelay(bytes: Int, wifi: Bool) -> TimeInterval {
        wifi ? 4 : min(60, 8 + Double(max(0, bytes)) * 0.008)
    }
}
