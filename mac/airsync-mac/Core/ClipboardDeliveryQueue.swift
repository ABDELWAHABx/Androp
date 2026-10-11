import Foundation

/// Only the head is in flight: an old retry must never overwrite a newer clipboard.
/// Deadlines use monotonic uptime so clock/time-zone changes cannot stall delivery.
struct ClipboardDeliveryQueue {
    struct Entry {
        let id: String
        let text: String
        let videoHandoff: Bool
        let explicit: Bool
        var attempts = 0
        var deadline: TimeInterval = 0
    }
    private(set) var entries: [Entry] = []
    var isEmpty: Bool { entries.isEmpty }
    var nextDeadline: TimeInterval? { entries.first?.deadline }

    mutating func enqueue(text: String, videoHandoff: Bool, explicit: Bool) -> Bool {
        let bytes = text.utf8.count
        guard bytes > 0, bytes <= 64 * 1024 else { return false }
        if !explicit {
            if entries.last?.text == text { return false }
            entries.removeAll { !$0.explicit && $0.attempts == 0 }
            if entries.last?.text == text { return false }
        }
        guard entries.count < 8,
              entries.reduce(0, { $0 + $1.text.utf8.count }) + bytes <= 512 * 1024 else { return false }
        entries.append(Entry(id: UUID().uuidString, text: text, videoHandoff: videoHandoff, explicit: explicit))
        return true
    }

    func due(at uptime: TimeInterval) -> Entry? {
        guard let first = entries.first, first.attempts < 3, first.deadline <= uptime else { return nil }
        return first
    }

    mutating func attempted(id: String, at uptime: TimeInterval, delay: TimeInterval) {
        guard entries.first?.id == id else { return }
        entries[0].attempts += 1
        entries[0].deadline = uptime + delay
    }

    /// The transport refused the write (queue full, link changing): retry soon
    /// without spending one of the three delivery attempts.
    mutating func notSent(id: String, at uptime: TimeInterval) {
        guard entries.first?.id == id, entries[0].attempts > 0 else { return }
        entries[0].attempts -= 1
        entries[0].deadline = uptime + 1
    }

    mutating func acknowledge(id: String) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].attempts > 0 else { return nil }
        return entries.remove(at: index)
    }

    @discardableResult
    mutating func expire(at uptime: TimeInterval) -> Bool {
        guard let first = entries.first, first.attempts >= 3, first.deadline <= uptime else { return false }
        entries.removeFirst()
        return true
    }

    mutating func removeAll() { entries.removeAll() }
}
