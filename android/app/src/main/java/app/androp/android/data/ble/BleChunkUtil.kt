package app.androp.android.data.ble


object BleChunkUtil {
    private const val MAX_MESSAGE_BYTES = 256 * 1024
    private const val ASSEMBLY_TIMEOUT_MS = 30_000L

    /**
     * Splits a string payload into chunks suitable for BLE transmission.
     * Each chunk starts with a 4-byte, big-endian header: [UInt16 index, UInt16 total].
     * mtu is the maximum characteristic value length (ATT MTU minus 3 on Android).
     */
    fun splitIntoChunks(payload: String, mtu: Int): List<ByteArray> {
        val data = payload.toByteArray(Charsets.UTF_8)
        val maxPayloadSize = mtu - BleConstants.CHUNK_HEADER_SIZE

        if (maxPayloadSize <= 0) {
            return emptyList()
        }

        if (data.size > MAX_MESSAGE_BYTES) return emptyList()
        val totalChunks = maxOf(1, (data.size + maxPayloadSize - 1) / maxPayloadSize)
        if (totalChunks > 0xFFFF) return emptyList()
        val chunks = mutableListOf<ByteArray>()

        for (i in 0 until totalChunks) {
            val start = i * maxPayloadSize
            val end = minOf(start + maxPayloadSize, data.size)
            val chunkData = data.sliceArray(start until end)

            val chunk = ByteArray(BleConstants.CHUNK_HEADER_SIZE + chunkData.size)
            val buffer = java.nio.ByteBuffer.wrap(chunk)
            buffer.putShort(i.toShort())
            buffer.putShort(totalChunks.toShort())

            chunkData.copyInto(chunk, BleConstants.CHUNK_HEADER_SIZE)
            chunks.add(chunk)
        }

        return chunks
    }

    /**
     * Reassembles chunks into the original string.
     * Expects a map of index to chunk data (without the header).
     */
    fun reassemble(chunks: Map<Int, ByteArray>): String {
        val sortedIndices = chunks.keys.sorted()
        if (sortedIndices.isEmpty()) return ""

        val totalSize = chunks.values.sumOf { it.size }
        val result = ByteArray(totalSize)

        var offset = 0
        for (index in sortedIndices) {
            val chunk = chunks[index] ?: continue
            chunk.copyInto(result, offset)
            offset += chunk.size
        }

        return String(result, Charsets.UTF_8)
    }

    /**
     * Extracts header information from a raw BLE packet.
     */
    fun parseHeader(packet: ByteArray): Pair<Int, Int>? {
        if (packet.size < BleConstants.CHUNK_HEADER_SIZE) return null
        val buffer = java.nio.ByteBuffer.wrap(packet)
        val current = buffer.short.toInt() and 0xFFFF
        val total = buffer.short.toInt() and 0xFFFF
        if (total == 0 || current >= total || total > MAX_MESSAGE_BYTES) return null
        return Pair(current, total)
    }

    /**
     * Extracts payload data from a raw BLE packet (strips header).
     */
    fun getPayload(packet: ByteArray): ByteArray {
        if (packet.size <= BleConstants.CHUNK_HEADER_SIZE) return byteArrayOf()
        return packet.sliceArray(BleConstants.CHUNK_HEADER_SIZE until packet.size)
    }

    /**
     * Helper class to reassemble chunks as they arrive.
     */
    class Reassembler(private val maxMessageBytes: Int = MAX_MESSAGE_BYTES) {
        private val chunks = mutableMapOf<Int, ByteArray>()
        private var totalChunks = -1
        private var byteCount = 0
        private var lastChunkTimeMs = 0L

        @Synchronized
        fun addChunk(packet: ByteArray, nowMs: Long = System.nanoTime() / 1_000_000): String? {
            val (current, total) = parseHeader(packet) ?: run { clear(); return null }
            // The wire format has no message ID. Index zero starts a new message;
            // never combine abandoned fragments with another message of equal length.
            if (current == 0 || nowMs - lastChunkTimeMs > ASSEMBLY_TIMEOUT_MS) clear()
            if (totalChunks == -1) {
                if (current != 0) return null
                totalChunks = total
            }
            if (totalChunks != total || current != chunks.size) {
                clear()
                return null
            }
            val payload = getPayload(packet)
            if (total > maxMessageBytes || byteCount + payload.size > maxMessageBytes) {
                clear()
                return null
            }
            chunks[current] = payload
            byteCount += payload.size
            lastChunkTimeMs = nowMs
            if (chunks.size != totalChunks) return null
            val result = reassemble(chunks)
            clear()
            return result
        }

        @Synchronized
        fun clear() {
            chunks.clear()
            totalChunks = -1
            byteCount = 0
            lastChunkTimeMs = 0
        }
    }
}
