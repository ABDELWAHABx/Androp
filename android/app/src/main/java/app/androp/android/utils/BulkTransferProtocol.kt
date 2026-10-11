package app.androp.android.utils

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.nio.ByteBuffer
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Raw, encrypted file stream between phone and Mac — the fast path (like ShareIt over a
 * local network): no Base64, no JSON, no per-chunk acknowledgements. The per-transfer key
 * travels only inside the already authenticated and encrypted control connection.
 *
 * Wire: repeated [u32 big-endian length][AES-256-GCM ciphertext+tag]. The 12-byte nonce is
 * [u32 direction][u64 counter], never sent, so a reordered, replayed or injected record
 * fails authentication. Plaintext is [u8 type][payload]. Must match BulkTransferProtocol.swift.
 */
object BulkTransferProtocol {
    const val MAC_TO_PHONE = 1
    const val PHONE_TO_MAC = 2
    const val TYPE_DATA: Byte = 1
    const val TYPE_END: Byte = 2
    const val TYPE_HELLO: Byte = 3
    const val MAX_PAYLOAD = 1024 * 1024
    private const val TAG_BYTES = 16

    class Record(val type: Byte, val payload: ByteArray, val length: Int = payload.size)

    fun nonce(direction: Int, counter: Long): ByteArray =
        ByteBuffer.allocate(12).putInt(direction).putLong(counter).array()

    /** One direction of a stream; keeps its own record counter. */
    class Sealer(key: ByteArray, private val direction: Int) {
        private val keySpec = SecretKeySpec(key.copyOf(), "AES")
        private val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        private var counter = 0L

        init { require(key.size == 32) { "Bulk key must be 256-bit" } }

        fun seal(type: Byte, payload: ByteArray, offset: Int = 0, length: Int = payload.size): ByteArray {
            require(length in 0..MAX_PAYLOAD)
            cipher.init(Cipher.ENCRYPT_MODE, keySpec, GCMParameterSpec(128, nonce(direction, counter++)))
            cipher.update(byteArrayOf(type))
            return cipher.doFinal(payload, offset, length)
        }

        fun write(out: DataOutputStream, type: Byte, payload: ByteArray, offset: Int = 0, length: Int = payload.size) {
            val sealed = seal(type, payload, offset, length)
            out.writeInt(sealed.size)
            out.write(sealed)
        }

        fun open(sealed: ByteArray): Record {
            require(sealed.size in TAG_BYTES + 1..MAX_PAYLOAD + 1 + TAG_BYTES) { "Invalid record" }
            cipher.init(Cipher.DECRYPT_MODE, keySpec, GCMParameterSpec(128, nonce(direction, counter++)))
            val plain = cipher.doFinal(sealed)
            return Record(plain[0], plain.copyOfRange(1, plain.size))
        }

        /** Reads one record; null at a clean end of stream before a header. */
        fun read(input: DataInputStream, buffer: ByteArray? = null): Record? {
            val length = try { input.readInt() } catch (_: EOFException) { return null }
            require(length in TAG_BYTES + 1..MAX_PAYLOAD + 1 + TAG_BYTES) { "Invalid record length" }
            val sealed = if (buffer != null && buffer.size == length) buffer else ByteArray(length)
            input.readFully(sealed, 0, length)
            return open(sealed)
        }
    }

    fun newKey(): ByteArray = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
}
