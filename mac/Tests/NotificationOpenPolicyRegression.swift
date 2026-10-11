import Foundation

@main
struct NotificationOpenPolicyRegression {
    static func main() {
        typealias P = NotificationOpenPolicy
        let post = "https://www.reddit.com/r/androiddev/comments/abc/title/"
        let reddit = P.Target.web("https://www.reddit.com")

        precondition(P.clickDestination(link: post, canOpenOnPhone: true, target: reddit, openOnPhoneWithoutLink: true)
                     == .link(URL(string: post)!), "Same-site deep link opens the exact content")
        precondition(P.clickDestination(link: "https://old.reddit.com/r/x", canOpenOnPhone: false, target: .web("reddit.com"),
                                        openOnPhoneWithoutLink: false) == .link(URL(string: "https://old.reddit.com/r/x")!))
        precondition(P.clickDestination(link: "https://youtu.be/x", canOpenOnPhone: false, target: .web("https://web.whatsapp.com"),
                                        openOnPhoneWithoutLink: false) == .launchTarget,
                     "A link shared in a chat must not replace the configured app page")
        precondition(P.clickDestination(link: "https://youtu.be/x", canOpenOnPhone: true, target: .macApp,
                                        openOnPhoneWithoutLink: true) == .phone)
        precondition(P.clickDestination(link: post, canOpenOnPhone: false, target: .macApp, openOnPhoneWithoutLink: false)
                     == .launchTarget, "An explicitly chosen Mac app keeps priority")
        precondition(P.clickDestination(link: post, canOpenOnPhone: true, target: .disabled, openOnPhoneWithoutLink: true)
                     == .nothing, "Disabled packages never open anything")
        precondition(P.clickDestination(link: post, canOpenOnPhone: false, target: .none, openOnPhoneWithoutLink: false)
                     == .link(URL(string: post)!))
        precondition(P.clickDestination(link: nil, canOpenOnPhone: false, target: .none, openOnPhoneWithoutLink: true) == .nothing,
                     "Old phones never advertise phone opening")
        precondition(P.clickDestination(link: nil, canOpenOnPhone: true, target: reddit, openOnPhoneWithoutLink: false) == .launchTarget,
                     "Without a link, the existing click behavior is unchanged by default")
        precondition(P.clickDestination(link: nil, canOpenOnPhone: true, target: reddit, openOnPhoneWithoutLink: true) == .phone)

        precondition(P.sanitizedLink("javascript:alert(1)") == nil)
        precondition(P.sanitizedLink("file:///etc/hosts") == nil)
        precondition(P.sanitizedLink("https://reddit.com@evil.example/") == nil, "Credentials disguise the real host")
        precondition(P.sanitizedLink("https://localhost/") == nil)
        precondition(P.sanitizedLink("https://example.com/" + String(repeating: "a", count: P.maxLinkLength)) == nil)
        precondition(P.isSameSite(URL(string: "https://news.bbc.co.uk/a")!, as: "https://www.bbc.co.uk"))
        precondition(!P.isSameSite(URL(string: "https://evil.co.uk/a")!, as: "https://www.bbc.co.uk"))
        precondition(!P.isSameSite(URL(string: "https://notreddit.com/a")!, as: "reddit.com"))
        precondition(P.openOnPhoneAction == "androp.openOnPhone", "Must match NotificationLinkPolicy on Android")
        print("Notification open policy: 19 checks passed")
    }
}
