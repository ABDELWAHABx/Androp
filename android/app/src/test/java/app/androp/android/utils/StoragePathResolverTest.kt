package app.androp.android.utils

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

class StoragePathResolverTest {
    private val root = File("/tmp/androp-test-storage")

    @Test fun providerDisplayNamesCannotBecomeCachePaths() {
        assertEquals("photo.jpg", StoragePathResolver.safeFileName("../../photo.jpg", "shared"))
        assertEquals("photo.jpg", StoragePathResolver.safeFileName("C:\\private\\photo.jpg", "shared"))
        assertEquals("shared", StoragePathResolver.safeFileName("..", "shared"))
        assertEquals("shared", StoragePathResolver.safeFileName("/", "shared"))
        assertEquals("nul_name", StoragePathResolver.safeFileName("nul\u0000name", "shared"))
    }

    @Test fun legitimateProviderNamesArePreserved() {
        assertEquals("رحلة + 2026.jpg", StoragePathResolver.safeFileName("رحلة + 2026.jpg", "shared"))
        assertEquals(".hidden", StoragePathResolver.safeFileName(".hidden", "shared"))
    }

    @Test fun nestedPathResolvesInsideStorage() {
        assertEquals(File(root, "DCIM/Camera").canonicalFile, StoragePathResolver.resolve(root, "DCIM/Camera"))
    }

    @Test fun traversalAndSiblingPrefixesAreRejected() {
        assertNull(StoragePathResolver.resolve(root, "../private"))
        assertNull(StoragePathResolver.resolve(root, "/tmp/androp-test-storage-other", allowAbsolute = true))
    }

    @Test fun normalAbsoluteBrowsePathIsAccepted() {
        assertEquals(File(root, "Downloads").canonicalFile,
            StoragePathResolver.resolve(root, File(root, "Downloads").path, allowAbsolute = true))
    }
}
