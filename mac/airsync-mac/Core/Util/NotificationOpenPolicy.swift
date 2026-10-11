import Foundation

/// Decides what clicking a mirrored Android notification opens.
/// Android hides the target of another app's tap intent, so a phone can only send
/// links visible in the notification, plus whether it can open the content itself.
nonisolated enum NotificationOpenPolicy {
    /// Reserved notificationAction name; the phone fires the notification's own tap intent.
    static let openOnPhoneAction = "androp.openOnPhone"
    static let maxLinkLength = 1024

    /// The Mac-side click preference for a package, without AppKit details.
    enum Target: Equatable {
        case none
        case disabled
        case macApp
        case web(String)
    }

    enum Destination: Equatable {
        case link(URL)
        case phone
        case launchTarget
        case nothing
    }

    /// Accept only bounded http(s) links with a real host and no credentials.
    static func sanitizedLink(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              raw.utf8.count <= maxLinkLength,
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }

    /// True when the link is on the same site as the configured web page, so it is the
    /// app's own content rather than, for example, a link someone sent in a chat.
    static func isSameSite(_ link: URL, as base: String) -> Bool {
        let withScheme = base.lowercased().hasPrefix("http") ? base : "https://\(base)"
        guard let linkSite = link.host.map(registrableDomain), let baseSite = URL(string: withScheme)?.host.map(registrableDomain),
              linkSite.contains(".") else { return false }
        return linkSite == baseSite
    }

    static func clickDestination(link rawLink: String?, canOpenOnPhone: Bool,
                                 target: Target, openOnPhoneWithoutLink: Bool) -> Destination {
        if target == .disabled { return .nothing }
        if let link = sanitizedLink(rawLink) {
            switch target {
            case .none: return .link(link)
            case .web(let base) where isSameSite(link, as: base): return .link(link)
            default: break
            }
        }
        if openOnPhoneWithoutLink && canOpenOnPhone { return .phone }
        return target == .none ? .nothing : .launchTarget
    }

    /// Approximates the registrable domain: the last two labels, or three under a
    /// two-letter country suffix such as co.uk or com.au.
    private static func registrableDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let countrySecondLevel = labels[labels.count - 1].count == 2 && labels[labels.count - 2].count <= 3
        return labels.suffix(countrySecondLevel ? 3 : 2).joined(separator: ".")
    }
}
