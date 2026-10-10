package app.androp.android.quickshare

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.OutputStream

class QuickShareConnectionTest {
    @Test fun closeAttemptsBothStreamsOnceEvenWhenInputCloseFails() {
        var inputCloses = 0
        var outputCloses = 0
        val input = object : ByteArrayInputStream(byteArrayOf()) {
            override fun close() { inputCloses++; throw java.io.IOException("peer closed") }
        }
        val output = object : ByteArrayOutputStream() {
            override fun close() { outputCloses++ }
        }
        val connection = QuickShareConnection(input, output)
        connection.close()
        connection.close()
        assertEquals(1, inputCloses)
        assertEquals(1, outputCloses)
    }

    @Test(expected = java.io.IOException::class)
    fun delayedSendAfterCancelCannotWriteAnotherFrame() {
        val connection = QuickShareConnection(ByteArrayInputStream(byteArrayOf()), ByteArrayOutputStream())
        connection.close()
        connection.writeFrame(byteArrayOf(1))
    }

    @Test(expected = java.io.IOException::class)
    fun delayedReadAfterCancelCannotConsumeBufferedFrame() {
        val connection = QuickShareConnection(ByteArrayInputStream(byteArrayOf(0, 0, 0, 1, 9)), ByteArrayOutputStream())
        connection.close()
        connection.readFrame()
    }

    @Test fun framingSurvivesFragmentedReads() {
        val encoded = ByteArrayOutputStream()
        DataOutputStream(encoded).use {
            it.writeInt(3)
            it.write(byteArrayOf(1, 2, 3))
            it.writeInt(0)
        }
        val input = object : ByteArrayInputStream(encoded.toByteArray()) {
            override fun read(b: ByteArray, off: Int, len: Int): Int = super.read(b, off, minOf(len, 1))
        }
        val connection = QuickShareConnection(input, ByteArrayOutputStream())
        assertArrayEquals(byteArrayOf(1, 2, 3), connection.readFrame())
        assertEquals(0, connection.readFrame().size)
        connection.close()
    }

    @Test fun smallFrameCombinesPrefixAndPayloadIntoOneSocketWrite() {
        val bytes = ByteArrayOutputStream()
        var writes = 0
        val output = object : OutputStream() {
            override fun write(b: Int) { writes++; bytes.write(b) }
            override fun write(b: ByteArray, off: Int, len: Int) { writes++; bytes.write(b, off, len) }
        }
        val connection = QuickShareConnection(ByteArrayInputStream(byteArrayOf()), output)
        connection.writeFrame(byteArrayOf(7, 8, 9))
        assertEquals(1, writes)
        assertArrayEquals(byteArrayOf(0, 0, 0, 3, 7, 8, 9), bytes.toByteArray())
        connection.close()
    }

    @Test(expected = IllegalStateException::class)
    fun oversizedFrameFailsBeforeAllocatingPayload() {
        val bytes = ByteArrayOutputStream()
        DataOutputStream(bytes).writeInt(10 * 1024 * 1024 + 1)
        QuickShareConnection(ByteArrayInputStream(bytes.toByteArray()), ByteArrayOutputStream()).readFrame()
    }
}
