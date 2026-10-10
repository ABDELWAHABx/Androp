package app.androp.android.utils

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.CancellationException

class OutgoingShareCacheTest {
    private fun source(name: String, bytes: ByteArray = byteArrayOf(1, 2, 3)) =
        OutgoingShareCache.Source(name) { ByteArrayInputStream(bytes) }
    private fun withRoot(test: (java.io.File) -> Unit) {
        val root = Files.createTempDirectory("androp-share-test").toFile()
        try { test(root) } finally { root.deleteRecursively() }
    }
    @Test fun duplicateNamesKeepEveryFileAndExistingData() = withRoot { root ->
        java.io.File(root, "image.jpg").writeText("existing")
        val files = OutgoingShareCache.stage(root, listOf(source("image.jpg"), source("image.jpg", byteArrayOf(4))))
        assertEquals(listOf("image (1).jpg", "image (2).jpg"), files.map { it.name })
        assertEquals("existing", java.io.File(root, "image.jpg").readText())
        assertArrayEquals(byteArrayOf(4), files[1].readBytes())
    }
    @Test fun failedProviderRollsBackWholeSelection() = withRoot { root ->
        val sources = listOf(source("one"), OutgoingShareCache.Source("two") { throw IOException("lost grant") })
        try { OutgoingShareCache.stage(root, sources); fail("Expected provider failure") } catch (_: IOException) {}
        assertEquals(0, root.listFiles()!!.size)
    }
    @Test fun lowStorageDeletesPartialFile() = withRoot { root ->
        try { OutgoingShareCache.stage(root, listOf(source("one")), availableBytes = { 0 }); fail("Expected no-space failure") }
        catch (_: IOException) {}
        assertEquals(0, root.listFiles()!!.size)
    }
    @Test fun cancellationDuringStreamingDeletesPartialBatch() = withRoot { root ->
        var calls = 0
        try {
            OutgoingShareCache.stage(root, listOf(source("one", ByteArray(300_000))), checkActive = {
                if (++calls == 4) throw CancellationException()
            })
            fail("Expected cancellation")
        } catch (_: CancellationException) {}
        assertEquals(0, root.listFiles()!!.size)
    }
    @Test fun largeFileUsesBoundedReads() = withRoot { root ->
        val bytes = ByteArray(5 * 1024 * 1024) { (it % 251).toByte() }
        val source = OutgoingShareCache.Source("large") {
            object : ByteArrayInputStream(bytes) {
                override fun read(b: ByteArray, off: Int, len: Int): Int {
                    assertTrue("Read buffer must stay bounded", len <= 64 * 1024)
                    return super.read(b, off, len)
                }
            }
        }
        assertArrayEquals(bytes, OutgoingShareCache.stage(root, listOf(source)).single().readBytes())
    }
    @Test fun unicodeLongAndTraversalNamesRemainContained() = withRoot { root ->
        val files = OutgoingShareCache.stage(root, listOf(source("../" + "ص".repeat(180) + ".jpg"), source("..")))
        assertTrue(files.all { it.canonicalFile.parentFile == root.canonicalFile })
        assertTrue(files.all { it.name.toByteArray(Charsets.UTF_8).size <= 240 })
    }
    @Test fun emptyAndOversizedBatchesAreRejected() = withRoot { root ->
        for (batch in listOf(emptyList(), List(257) { source("file") })) {
            try { OutgoingShareCache.stage(root, batch); fail("Expected bounded batch") }
            catch (_: IllegalArgumentException) {}
        }
        assertEquals(0, root.listFiles()!!.size)
    }
}
