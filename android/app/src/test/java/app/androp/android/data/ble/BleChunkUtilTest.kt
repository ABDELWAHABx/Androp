package app.androp.android.data.ble

import org.junit.Assert.*
import org.junit.Test

class BleChunkUtilTest {
    @Test fun unicodeRoundTripsWithinAttPayloadLimits() {
        val text = "Hello مرحبا 👋 café".repeat(100)
        for (attMtu in listOf(23, 185, 247, 517)) {
            val packets = BleChunkUtil.splitIntoChunks(text, attMtu - 3)
            assertTrue(packets.all { it.size <= attMtu - 3 })
            val assembler = BleChunkUtil.Reassembler()
            val results = packets.mapNotNull { assembler.addChunk(it) }
            assertEquals(listOf(text), results)
        }
    }

    @Test fun emptyPayloadHasAnExplicitFrame() {
        val packets = BleChunkUtil.splitIntoChunks("", 20)
        assertEquals(1, packets.size)
        assertArrayEquals(byteArrayOf(0, 0, 0, 1), packets.single())
        assertEquals("", BleChunkUtil.Reassembler().addChunk(packets.single()))
    }

    @Test fun invalidHeadersAndOversizedMessagesAreRejected() {
        assertNull(BleChunkUtil.parseHeader(byteArrayOf(0, 0, 0, 0)))
        assertNull(BleChunkUtil.parseHeader(byteArrayOf(0, 2, 0, 2)))
        assertNull(BleChunkUtil.parseHeader(byteArrayOf(0)))
        assertTrue(BleChunkUtil.splitIntoChunks("hello", 4).isEmpty())
        assertTrue(BleChunkUtil.splitIntoChunks("x".repeat(256 * 1024 + 1), 20).isEmpty())
    }

    @Test fun abandonedMessageCannotContaminateNextMessageWithTheSameChunkCount() {
        val old = BleChunkUtil.splitIntoChunks("old-message-contents", 12)
        val next = BleChunkUtil.splitIntoChunks("new-message-contents", 12)
        assertEquals(old.size, next.size)
        val assembler = BleChunkUtil.Reassembler()
        assertNull(assembler.addChunk(old[0], 100))
        assertNull(assembler.addChunk(old[1], 101))
        assertEquals(listOf("new-message-contents"), next.mapNotNull { assembler.addChunk(it, 102) })
    }

    @Test fun missingOutOfOrderAndExpiredFragmentsDoNotProduceCorruptMessages() {
        val packets = BleChunkUtil.splitIntoChunks("a reasonably long message", 12)
        val assembler = BleChunkUtil.Reassembler()
        assertNull(assembler.addChunk(packets[1], 100))
        assertNull(assembler.addChunk(packets[0], 101))
        assertNull(assembler.addChunk(packets[2], 102))
        assertNull(assembler.addChunk(packets[0], 103))
        assertNull(assembler.addChunk(packets[1], 30_104))
        assertEquals(listOf("a reasonably long message"), packets.mapNotNull { assembler.addChunk(it, 30_105) })
    }
}
