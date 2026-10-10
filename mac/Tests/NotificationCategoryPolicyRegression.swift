import Foundation

@main
struct NotificationCategoryPolicyRegression {
    static func main() {
        let reply = NotificationCategoryPolicy.identifier(for: ["ACT_Reply", "Reply", "reply"])
        let button = NotificationCategoryPolicy.identifier(for: ["ACT_Reply", "Reply", "button"])
        precondition(reply != button, "Same title with different input type must not reuse category")
        precondition(reply == NotificationCategoryPolicy.identifier(for: ["ACT_Reply", "Reply", "reply"]))
        precondition(NotificationCategoryPolicy.identifier(for: ["a_b", "c"]) !=
                     NotificationCategoryPolicy.identifier(for: ["a", "b_c"]))
        precondition(NotificationCategoryPolicy.identifier(for: ["1:ab", "c"]) !=
                     NotificationCategoryPolicy.identifier(for: ["1:a", "bc"]))
        precondition(reply.count == 68, "Long/localized action labels must not grow category identifiers")
        precondition(NotificationCategoryPolicy.removed(previouslyDelivered: [], currentlyDelivered: [], mirrored: ["never-posted"]).isEmpty,
                     "Muted, pending, or denied notification is not an Android dismissal")
        precondition(NotificationCategoryPolicy.removed(previouslyDelivered: ["message"], currentlyDelivered: [], mirrored: ["message"]) == ["message"])
        precondition(NotificationCategoryPolicy.removed(previouslyDelivered: ["message"], currentlyDelivered: ["message"], mirrored: ["message"]).isEmpty)
        precondition(NotificationCategoryPolicy.removed(previouslyDelivered: ["local-call"], currentlyDelivered: [], mirrored: ["message"]).isEmpty)
        precondition(NotificationCategoryPolicy.evictions(oldestFirst: ["old", "visible", "recent"], protected: ["visible", "recent"], limit: 2) == ["old"])
        precondition(NotificationCategoryPolicy.evictions(oldestFirst: ["one", "two"], protected: ["one", "two"], limit: 1).isEmpty,
                     "Do not break actions on visible notifications just to meet the cache limit")
        precondition(NotificationCategoryPolicy.evictions(oldestFirst: ["one"], protected: [], limit: 2).isEmpty)
        print("Notification category/dismissal policy: 12 checks passed")
    }
}
