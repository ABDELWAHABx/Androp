package app.androp.android.utils

/** Bounds incoming chunk offsets before multiplication or disk access. */
internal object FileTransferValidation {
    const val MIN_CHUNK_SIZE = 16 * 1024
    const val MAX_CHUNK_SIZE = 1024 * 1024

    fun expectedChunkLength(size: Long, chunkSize: Int, index: Long): Int? {
        if (size < 0 || chunkSize !in MIN_CHUNK_SIZE..MAX_CHUNK_SIZE || index < 0) return null
        val lastIndex = if (size == 0L) 0 else (size - 1) / chunkSize
        if (index > lastIndex || index > Int.MAX_VALUE) return null
        val offset = index * chunkSize
        return minOf(chunkSize.toLong(), size - offset).toInt()
    }
}
