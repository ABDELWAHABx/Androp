package app.androp.android.utils

import org.junit.Assert.*
import org.junit.Test

class WebDavAccessPolicyTest {
    private val token = "ab".repeat(32)
    private val prefix = WebDavAccessPolicy.prefix(token)

    @Test fun capabilityIsFreshAnd256Bits() {
        val first = WebDavAccessPolicy.newToken()
        assertTrue(first.matches(Regex("[0-9a-f]{64}")))
        assertNotEquals(first, WebDavAccessPolicy.newToken())
    }
    @Test fun anonymousAndRevokedMountsFailClosed() {
        assertNull(WebDavAccessPolicy.relativePath("/DCIM/test.jpg", token))
        assertNull(WebDavAccessPolicy.relativePath(prefix, null))
        assertNull(WebDavAccessPolicy.relativePath("/", token))
    }
    @Test fun wrongOrMalformedTokenCannotRead() {
        assertNull(WebDavAccessPolicy.relativePath(WebDavAccessPolicy.prefix("cd".repeat(32)), token))
        assertNull(WebDavAccessPolicy.relativePath("/.androp/ab/", token))
        assertNull(WebDavAccessPolicy.relativePath(prefix, "invalid"))
    }
    @Test fun rootAndUnicodeNamesPreservePlusAndSpace() {
        assertEquals("", WebDavAccessPolicy.relativePath(prefix, token))
        assertEquals("DCIM/a+b c.jpg", WebDavAccessPolicy.relativePath(prefix + "DCIM/a+b%20c.jpg", token))
        assertEquals("صور.jpg", WebDavAccessPolicy.relativePath(prefix + "%D8%B5%D9%88%D8%B1.jpg", token))
    }
    @Test fun traversalAndMalformedEscapesAreRejected() {
        for (path in listOf("../secret", "%2e%2e/secret", "a/../../secret", "a%5cb", "%00", "%QZ", "a/./b")) {
            assertNull(path, WebDavAccessPolicy.relativePath(prefix + path, token))
        }
    }
    @Test fun depthNeverRecursesUnbounded() {
        assertTrue(WebDavAccessPolicy.supportsDepth(null))
        assertTrue(WebDavAccessPolicy.supportsDepth("0"))
        assertTrue(WebDavAccessPolicy.supportsDepth("1"))
        assertFalse(WebDavAccessPolicy.supportsDepth("infinity"))
        assertFalse(WebDavAccessPolicy.supportsDepth("2"))
    }
}
