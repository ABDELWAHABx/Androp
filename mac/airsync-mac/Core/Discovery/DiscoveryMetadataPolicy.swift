import Foundation

/// DNS-SD instance labels and individual TXT records have byte limits, not character limits.
enum DiscoveryMetadataPolicy {
    static func displayName(_ name: String?) -> String {
        let cleaned = String(String.UnicodeScalarView((name ?? "").unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Mac" : cleaned
    }

    static func serviceName(_ name: String?, stableID: String) -> String {
        let candidate = "androp-" + displayName(name)
        guard candidate.utf8.count > 63 else { return candidate }
        let id = String(stableID.lowercased().filter { "0123456789abcdef".contains($0) }.prefix(8))
        let suffix = id.isEmpty ? "" : "-" + id
        return utf8Prefix(candidate, limit: 63 - suffix.utf8.count) + suffix
    }

    static func txtName(_ name: String?) -> String {
        // The full record is "name=" (five bytes) plus its UTF-8 value, at most 255 bytes.
        utf8Prefix(displayName(name), limit: 250)
    }

    private static func utf8Prefix(_ value: String, limit: Int) -> String {
        var bytes = 0
        var result = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            let size = scalar.utf8.count
            guard bytes + size <= limit else { break }
            result.append(scalar)
            bytes += size
        }
        return String(result)
    }
}
