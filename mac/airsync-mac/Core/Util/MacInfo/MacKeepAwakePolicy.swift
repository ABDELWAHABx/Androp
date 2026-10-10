import Foundation

/// Pure monotonic-time policy. Enabling the preference alone never prevents sleep.
enum MacKeepAwakePolicy {
    nonisolated static func shouldUseExperimental(majorVersion: Int, enabled: Bool,
                                                connected: Bool, paused: Bool,
                                                activityReason: String?) -> Bool {
        majorVersion == 15 && enabled && connected && !paused && activityReason != nil
    }
    nonisolated static func reason(enabled: Bool, connected: Bool, paused: Bool,
                                  now: TimeInterval, transferUntil: TimeInterval,
                                  remoteUntil: TimeInterval, mediaUntil: TimeInterval) -> String? {
        guard enabled, connected, !paused, now.isFinite, now >= 0 else { return nil }
        if transferUntil.isFinite && transferUntil > now { return "File transfer" }
        if remoteUntil.isFinite && remoteUntil > now { return "Remote control" }
        if mediaUntil.isFinite && mediaUntil > now { return "Media playback" }
        return nil
    }
}
