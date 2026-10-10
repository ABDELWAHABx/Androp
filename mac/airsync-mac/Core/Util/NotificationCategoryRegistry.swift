import Foundation
import UserNotifications

/// Category writes replace the entire set. State belongs exclusively to this queue,
/// even when the app target defaults unannotated declarations to MainActor.
nonisolated final class NotificationCategoryRegistry: @unchecked Sendable {
    static let shared = NotificationCategoryRegistry()
    private let queue = DispatchQueue(label: "app.androp.notification-categories")
    private var categories: [String: UNNotificationCategory] = [:]
    private var recency: [String: UInt64] = [:]
    private var revision: UInt64 = 0
    private var pending: [(UNNotificationCategory, @MainActor @Sendable () -> Void)] = []
    private var loaded = false
    private var loading = false
    private var pruning = false
    private let dynamicLimit = 128

    func register(_ category: UNNotificationCategory, completion: @escaping @MainActor @Sendable () -> Void = {}) {
        queue.async {
            self.pending.append((category, completion))
            if self.loaded {
                self.flush()
            } else if !self.loading {
                self.loading = true
                UNUserNotificationCenter.current().getNotificationCategories { existing in
                    self.queue.async {
                        self.categories = Dictionary(existing.map { ($0.identifier, $0) }, uniquingKeysWith: { _, last in last })
                        self.loaded = true
                        self.loading = false
                        self.flush()
                    }
                }
            }
        }
    }

    private static func definition(_ category: UNNotificationCategory) -> String {
        var fields = [category.identifier, String(category.options.rawValue),
                      String(describing: category.hiddenPreviewsBodyPlaceholder),
                      String(describing: category.categorySummaryFormat), String(category.intentIdentifiers.count)]
        fields += category.intentIdentifiers
        for action in category.actions {
            fields += [action.identifier, action.title, String(action.options.rawValue)]
            if let reply = action as? UNTextInputNotificationAction {
                fields += ["reply", reply.textInputButtonTitle, reply.textInputPlaceholder]
            } else { fields.append("button") }
        }
        return NotificationCategoryPolicy.identifier(for: fields)
    }

    private func flush() {
        let registrations = pending
        pending.removeAll()
        var changed = false
        for (category, _) in registrations {
            revision &+= 1
            recency[category.identifier] = revision
            if categories[category.identifier].map(Self.definition) != Self.definition(category) {
                categories[category.identifier] = category
                changed = true
            }
        }
        if changed {
            UNUserNotificationCenter.current().setNotificationCategories(Set(categories.values))
        }
        // An unchanged category must still allow the notification itself to be posted.
        for (_, completion) in registrations { DispatchQueue.main.async(execute: completion) }
        if changed { pruneInactiveCategoriesIfNeeded() }
    }

    private func pruneInactiveCategoriesIfNeeded() {
        guard !pruning, categories.keys.filter({ $0.hasPrefix("DYN_") }).count > dynamicLimit else { return }
        pruning = true
        let snapshotRevision = revision
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let deliveredIDs = Set(delivered.map { $0.request.content.categoryIdentifier })
            center.getPendingNotificationRequests { pendingRequests in
                let protectedIDs = deliveredIDs.union(pendingRequests.map { $0.content.categoryIdentifier })
                self.queue.async {
                    self.pruning = false
                    // A category registered while the system snapshot was in flight may not
                    // appear there yet. Keep it along with every category on a visible alert.
                    let recentIDs = Set(self.recency.filter { $0.value >= snapshotRevision }.map(\.key))
                    let dynamic = self.categories.keys.filter { $0.hasPrefix("DYN_") }
                        .sorted { self.recency[$0, default: 0] < self.recency[$1, default: 0] }
                    let removable = NotificationCategoryPolicy.evictions(
                        oldestFirst: dynamic,
                        protected: protectedIDs.union(recentIDs).union(dynamic.suffix(self.dynamicLimit)),
                        limit: self.dynamicLimit)
                    for id in removable { self.categories.removeValue(forKey: id); self.recency.removeValue(forKey: id) }
                    if !removable.isEmpty { center.setNotificationCategories(Set(self.categories.values)) }
                    // The limit is soft only while more than 128 distinct categories are
                    // actually visible; pruning must not remove actions from existing alerts.
                }
            }
        }
    }
}
