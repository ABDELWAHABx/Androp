package app.androp.android.utils

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FileTransferValidationTest {
    @Test fun finalChunkUsesRemainingBytes() {
        assertEquals(16384, FileTransferValidation.expectedChunkLength(20000, 16384, 0))
        assertEquals(3616, FileTransferValidation.expectedChunkLength(20000, 16384, 1))
        assertNull(FileTransferValidation.expectedChunkLength(20000, 16384, 2))
    }
    @Test fun emptyFileAcceptsOnlyItsEmptyChunk() {
        assertEquals(0, FileTransferValidation.expectedChunkLength(0, 16384, 0))
        assertNull(FileTransferValidation.expectedChunkLength(0, 16384, 1))
    }
    @Test fun invalidIndexesAndChunkSizesCannotAllocateOrOverflow() {
        assertNull(FileTransferValidation.expectedChunkLength(10, 1, 0))
        assertNull(FileTransferValidation.expectedChunkLength(10, 16384, -1))
        assertNull(FileTransferValidation.expectedChunkLength(Long.MAX_VALUE, 16384, Long.MAX_VALUE))
        assertNull(FileTransferValidation.expectedChunkLength(-1, 16384, 0))
        assertNull(FileTransferValidation.expectedChunkLength(10, Int.MAX_VALUE, 0))
    }
}
