import Foundation

@main
struct ClipboardDeliveryRegression {
    static func main() {
        var queue = ClipboardDeliveryQueue()
        assert(queue.enqueue(text: "older", videoHandoff: false, explicit: false))
        let older = queue.due(at: 0)!
        queue.attempted(id: older.id, at: 0, delay: 4)
        assert(queue.enqueue(text: "newer", videoHandoff: false, explicit: false))
        let newerID = queue.entries[1].id
        assert(queue.due(at: 1) == nil, "Do not send a newer clipboard before an older delivery completes")
        assert(queue.nextDeadline == 4, "An unsent successor must not cause a zero-delay busy loop")
        assert(queue.acknowledge(id: newerID) == nil, "An unattempted message cannot be acknowledged")
        assert(queue.due(at: 4)?.id == older.id, "Only the head is retried")
        queue.attempted(id: older.id, at: 4, delay: 4)
        assert(queue.acknowledge(id: older.id)?.text == "older")
        assert(queue.acknowledge(id: older.id) == nil, "Duplicate ACK is ignored")
        assert(queue.due(at: 4)?.id == newerID, "ACK immediately unlocks the successor")
        for time in [4.0, 8.0, 12.0] { queue.attempted(id: newerID, at: time, delay: 4) }
        assert(queue.due(at: 16) == nil && !queue.expire(at: 15))
        assert(queue.expire(at: 16) && queue.isEmpty)
        assert(!queue.enqueue(text: String(repeating: "a", count: 65537), videoHandoff: false, explicit: true))
        assert(queue.enqueue(text: "same", videoHandoff: false, explicit: false))
        assert(!queue.enqueue(text: "same", videoHandoff: false, explicit: false))
        assert(queue.enqueue(text: "same", videoHandoff: true, explicit: true), "Explicit repeated handoff remains allowed")
        queue.removeAll()
        assert(queue.isEmpty && queue.nextDeadline == nil && queue.acknowledge(id: newerID) == nil)
        assert(queue.enqueue(text: "inflight", videoHandoff: false, explicit: false))
        let inflight = queue.due(at: 0)!
        queue.attempted(id: inflight.id, at: 0, delay: 4)
        assert(queue.enqueue(text: "obsolete", videoHandoff: false, explicit: false))
        assert(!queue.enqueue(text: "inflight", videoHandoff: false, explicit: false))
        assert(queue.entries.count == 1, "Returning to the in-flight value removes an obsolete successor")
        assert(queue.enqueue(text: "obsolete", videoHandoff: false, explicit: false))
        assert(queue.enqueue(text: "explicit", videoHandoff: true, explicit: true))
        assert(queue.enqueue(text: "latest", videoHandoff: false, explicit: false))
        assert(queue.entries.map(\.text) == ["inflight", "explicit", "latest"], "Coalesce automatic copies, retain intentional sends")
        print("Clipboard delivery regression checks passed")
    }
}
