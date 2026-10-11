package app.androp.android.utils

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream

class BulkTransferProtocolTest {
    private val key = ByteArray(32) { it.toByte() }

    // Same vector is checked by the Mac regression test.
    @Test fun sealMatchesSharedVector() {
        val sealed = BulkTransferProtocol.Sealer(key, BulkTransferProtocol.MAC_TO_PHONE)
            .seal(BulkTransferProtocol.TYPE_DATA, "androp".toByteArray())
        assertEquals("4557a3ce7e3584b57f8db32fa5ff0a3663c84a9c810e1f", sealed.joinToString("") { "%02x".format(it) })
    }

    @Test fun streamRoundTripsInOrder() {
        val bytes = ByteArrayOutputStream()
        val out = DataOutputStream(bytes)
        val sender = BulkTransferProtocol.Sealer(key, BulkTransferProtocol.PHONE_TO_MAC)
        sender.write(out, BulkTransferProtocol.TYPE_HELLO, "id-1".toByteArray())
        sender.write(out, BulkTransferProtocol.TYPE_DATA, ByteArray(300_000) { 7 })
        sender.write(out, BulkTransferProtocol.TYPE_END, "{}".toByteArray())
        val input = DataInputStream(ByteArrayInputStream(bytes.toByteArray()))
        val receiver = BulkTransferProtocol.Sealer(key, BulkTransferProtocol.PHONE_TO_MAC)
        assertArrayEquals("id-1".toByteArray(), receiver.read(input)!!.payload)
        assertEquals(300_000, receiver.read(input)!!.payload.size)
        assertEquals(BulkTransferProtocol.TYPE_END, receiver.read(input)!!.type)
        assertNull(receiver.read(input))
    }

    @Test fun reorderedOrWrongDirectionRecordsFail() {
        val first = BulkTransferProtocol.Sealer(key, 1).seal(1, byteArrayOf(1))
        val other = BulkTransferProtocol.Sealer(key, 2)
        assertThrows(Exception::class.java) { other.open(first) }
        val skip = BulkTransferProtocol.Sealer(key, 1)
        skip.seal(1, byteArrayOf(0))
        val second = skip.seal(1, byteArrayOf(2))
        assertThrows(Exception::class.java) { BulkTransferProtocol.Sealer(key, 1).open(second) }
    }
}
