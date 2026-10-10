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

    static func volumePercent(_ value: Float) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, 0), 1) * 100)
    }
}
