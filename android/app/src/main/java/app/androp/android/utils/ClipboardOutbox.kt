package app.androp.android.utils

import java.util.UUID

/** Bounded pending deliveries; enqueue/transport acceptance is never delivery. */
class ClipboardOutbox(private val maxEntries: Int = 8, private val maxBytes: Int = 512 * 1024) {
    data class Entry(val id: String, val text: String, val videoHandoff: Boolean,
        val explicit: Boolean = true, var attempts: Int = 0, var nextAttemptAtMs: Long = 0)
    private val pending = linkedMapOf<String, Entry>()
    private var lastDeliveredText: String? = null
    private var peerIdentity: String? = null

    @Synchronized fun enqueue(text: String, explicit: Boolean, videoHandoff: Boolean = false): Entry? {
        val bytes = text.toByteArray(Charsets.UTF_8).size
        if (text.isEmpty() || bytes > 64 * 1024) return null
        if (!explicit) {
            if (pending.values.lastOrNull()?.text == text) return null
            // Rapid copying should deliver the latest clipboard, not a backlog of
            // obsolete automatic values. In-flight and explicit sends keep ordering.
            pending.entries.removeAll { !it.value.explicit && it.value.attempts == 0 }
            if ((pending.isEmpty() && text == lastDeliveredText) || pending.values.lastOrNull()?.text == text) return null
        }
        if (pending.size >= maxEntries ||
            pending.values.sumOf { it.text.toByteArray(Charsets.UTF_8).size } + bytes > maxBytes) return null
        return Entry(UUID.randomUUID().toString(), text, videoHandoff, explicit).also { pending[it.id] = it }

    }
    @Synchronized fun due(nowMs: Long): Entry? = pending.values.firstOrNull()?.takeIf { it.attempts < 3 && it.nextAttemptAtMs <= nowMs }
    @Synchronized fun attempted(id: String, nowMs: Long, retryDelayMs: Long) {
        pending[id]?.let { it.attempts++; it.nextAttemptAtMs = nowMs + retryDelayMs }
    }
    @Synchronized fun acknowledge(id: String, ok: Boolean): Entry? {
        val entry = pending[id] ?: return null
        // Only attempted deliveries can succeed; a stale/forged ACK cannot deliver a queued successor.
        if (ok && entry.attempts == 0) return null
        pending.remove(id)
        if (ok) lastDeliveredText = entry.text
        return entry
    }
    @Synchronized fun expired(nowMs: Long): List<Entry> = pending.values
        .filter { it.attempts >= 3 && it.nextAttemptAtMs <= nowMs }.also { entries -> entries.forEach { pending.remove(it.id) } }
    @Synchronized fun nextDeadline(): Long? = pending.values.firstOrNull()?.nextAttemptAtMs
    @Synchronized fun reconnect() { pending.values.forEach { it.nextAttemptAtMs = 0 } }
    @Synchronized fun peerChanged(identity: String?): List<Entry> {
        if (peerIdentity == identity) return emptyList()
        peerIdentity = identity
        val removed = pending.values.toList()
        pending.clear()
        lastDeliveredText = null
        return removed
    }
    @Synchronized fun entries(): List<Entry> = pending.values.toList()
    @Synchronized fun clear() { pending.clear(); lastDeliveredText = null }
    @Synchronized fun size(): Int = pending.size
}
