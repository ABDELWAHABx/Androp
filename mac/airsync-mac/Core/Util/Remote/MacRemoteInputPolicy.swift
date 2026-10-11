import Foundation

/// Reject malformed remote numeric input before converting to C event types.
enum MacRemoteInputPolicy {
    static func scrollDelta(_ value: Double) -> Int32? {
        guard value.isFinite else { return nil }
        return Int32(min(max(value, -1_000_000), 1_000_000))
    }

    static func keyCode(_ value: Int) -> UInt16? {
        UInt16(exactly: value)
    }

    /// Any JSON number. The message decoder yields Int for integral values, so a
    /// plain `as? Double` cast silently rejected frames such as `"dy": 0`.
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: return value.isFinite ? value : nil
        case let value as Int: return Double(value)
        default: return nil
        }
    }

    /// Actions delivered as synthetic CGEvents, which macOS discards silently
    /// unless androp is allowed in Privacy & Security → Accessibility.
    static func needsAccessibility(_ action: String) -> Bool {
        action.hasPrefix("mouse_") || action.hasPrefix("arrow_") || action.hasPrefix("media_") ||
            ["keypress", "type", "enter", "space", "escape"].contains(action)
    }

    static func volumePercent(_ value: Float) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, 0), 1) * 100)
    }
}
