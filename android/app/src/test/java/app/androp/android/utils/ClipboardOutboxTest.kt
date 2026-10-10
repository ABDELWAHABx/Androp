package app.androp.android.utils

import org.junit.Assert.*
import org.junit.Test

class ClipboardOutboxTest {
    @Test fun enqueueAndQueueAcceptanceNeverMarkDelivered() {
        val outbox = ClipboardOutbox()
        val first = outbox.enqueue("hello", false)!!
        outbox.attempted(first.id, 100, 4000)
        assertEquals(1, outbox.size())
        assertNull(outbox.due(4099))
        assertEquals(first.id, outbox.due(4100)?.id)
        assertNull(outbox.enqueue("hello", false))
        assertNotNull(outbox.acknowledge(first.id, true))
        assertNull(outbox.acknowledge(first.id, true))
        assertNull(outbox.enqueue("hello", false))
        assertNotNull(outbox.enqueue("hello", true))
    }
    @Test fun failedAcknowledgementDoesNotSuppressResend() {
        val outbox = ClipboardOutbox()
        val first = outbox.enqueue("try again", false)!!
        assertNotNull(outbox.acknowledge(first.id, false))
        assertNotNull(outbox.enqueue("try again", false))
        assertNull(outbox.acknowledge("unrelated", true))
    }
    @Test fun retriesStopAfterThreeAttemptsAndDeadline() {
        val outbox = ClipboardOutbox()
        val entry = outbox.enqueue("hello", false)!!
        for (now in listOf(0L, 4000L, 8000L)) {
            assertEquals(entry.id, outbox.due(now)?.id)
            outbox.attempted(entry.id, now, 4000)
        }
        assertNull(outbox.due(12_000))
        assertTrue(outbox.expired(11_999).isEmpty())
        assertEquals(entry.id, outbox.expired(12_000).single().id)
        assertEquals(0, outbox.size())
        assertNotNull(outbox.enqueue("hello", false))
    }
    @Test fun reconnectMakesPendingDeliveryDueWithoutResettingAttemptCount() {
        val outbox = ClipboardOutbox()
        val entry = outbox.enqueue("hello", true)!!
        outbox.attempted(entry.id, 100, 60_000)
        outbox.reconnect()
        assertEquals(1, outbox.due(101)?.attempts)
        assertEquals(entry.id, outbox.due(101)?.id)
    }
    @Test fun changingPeerDropsPendingPrivateClipboardAndResetsDeduplication() {
        val outbox = ClipboardOutbox()
        outbox.peerChanged("peer-a")
        val delivered = outbox.enqueue("private", false)!!
        outbox.acknowledge(delivered.id, true)
        assertNull(outbox.enqueue("private", false))
        val pending = outbox.enqueue("pending private text", true)!!
        assertTrue(outbox.peerChanged("peer-a").isEmpty())
        assertEquals(1, outbox.size())
        assertEquals(pending.id, outbox.peerChanged("peer-b").single().id)
        assertEquals(0, outbox.size())
        assertNull(outbox.acknowledge(pending.id, true))
        assertNotNull(outbox.enqueue("private", false))
    }
    @Test fun messageQueueAndUtf8BytesAreBounded() {
        val outbox = ClipboardOutbox(maxEntries = 2, maxBytes = 10)
        assertNotNull(outbox.enqueue("مرحبا", true)) // 10 UTF-8 bytes.
        assertNull(outbox.enqueue("a", true))
        outbox.clear()
        assertNull(outbox.enqueue("x".repeat(64 * 1024 + 1), true))
        assertNotNull(outbox.enqueue("a", true))
        assertNotNull(outbox.enqueue("a", true))
        assertNull(outbox.enqueue("a", true))
    }
}
