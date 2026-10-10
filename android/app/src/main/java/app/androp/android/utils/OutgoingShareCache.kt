package app.androp.android.utils

import java.io.File
import java.io.IOException
import java.io.InputStream

/** Transactional, bounded-memory staging of provider files while a share grant is valid. */
internal object OutgoingShareCache {
    data class Source(val name: String, val open: () -> InputStream)
    private const val RESERVE_BYTES = 8L * 1024 * 1024

    fun stage(root: File, sources: List<Source>, checkActive: () -> Unit = {},
              availableBytes: () -> Long = { root.usableSpace }): List<File> {
        require(sources.isNotEmpty() && sources.size <= 256) { "Select between 1 and 256 files" }
        val directory = root.canonicalFile
        check(directory.isDirectory || directory.mkdirs()) { "Couldn't prepare files for sending" }
        val staged = mutableListOf<File>()
        try {
            for (source in sources) {
                checkActive()
                val name = StoragePathResolver.safeFileName(source.name, "shared_file")
                val file = reserve(directory, name)
                staged += file
                source.open().buffered(64 * 1024).use { input ->
                    file.outputStream().buffered(64 * 1024).use { output ->
                        val buffer = ByteArray(64 * 1024)
                        var budget = 0L
                        while (true) {
                            checkActive()
                            val count = input.read(buffer)
                            if (count < 0) break
                            if (count == 0) continue
                            if (budget < count) budget = (availableBytes() - RESERVE_BYTES).coerceAtMost(1024 * 1024)
                            if (budget < count) throw IOException("Not enough space to prepare these files")
                            output.write(buffer, 0, count)
                            budget -= count
                        }
                    }
                }
            }
            checkActive()
            return staged.toList()
        } catch (failure: Throwable) {
            staged.forEach { runCatching { it.delete() } }
            throw failure
        }
    }

    private fun reserve(root: File, name: String): File {
        val extension = name.substringAfterLast('.', "").take(24)
        val stem = if (extension.isEmpty()) name else name.substringBeforeLast('.')
        for (suffix in 0..10000) {
            val ending = (if (suffix == 0) "" else " ($suffix)") + (if (extension.isEmpty()) "" else ".$extension")
            // ext4/F2FS filename limits are bytes, not UTF-16 character counts.
            var safeStem = stem
            while ((safeStem + ending).toByteArray(Charsets.UTF_8).size > 240) safeStem = safeStem.dropLast(1)
            val candidate = requireNotNull(StoragePathResolver.resolve(root, safeStem + ending))
            require(candidate.parentFile == root) { "Invalid share filename" }
            if (candidate.createNewFile()) return candidate
        }
        throw IOException("Too many files with the same name")
    }
}
