import CryptoKit
import Foundation

nonisolated enum NotificationCategoryPolicy {
    /// Length framing avoids separator collisions; include type to distinguish Reply from a button.
    static func identifier(for fields: [String]) -> String {
        let key = fields.map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return "DYN_" + digest
    }

    static func evictions(oldestFirst: [String], protected: Set<String>, limit: Int) -> [String] {
        let excess = max(0, oldestFirst.count - max(0, limit))
        return Array(oldestFirst.filter { !protected.contains($0) }.prefix(excess))
    }

    /// Only an observed delivered notification can subsequently disappear from Notification Center.
    static func removed(previouslyDelivered: Set<String>, currentlyDelivered: Set<String>, mirrored: Set<String>) -> Set<String> {
        previouslyDelivered.subtracting(currentlyDelivered).intersection(mirrored)
    }
}
