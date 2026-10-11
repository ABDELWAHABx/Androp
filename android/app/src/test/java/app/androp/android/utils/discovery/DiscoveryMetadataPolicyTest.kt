package app.androp.android.utils.discovery

import org.junit.Assert.*
import org.junit.Test

class DiscoveryMetadataPolicyTest {
    private val stableId = "01234567-89ab-4cde-8fab-0123456789ab"

    @Test fun longHostnameFitsDnsLabelIncludingPrefixAndStableSuffix() {
        val original = "iad20-gt1026-07360297-c846-4134-b947-46902abc1817-3AF5ADFF4FC1"
        val name = DiscoveryMetadataPolicy.serviceName(original, stableId)
        assertTrue(name.toByteArray().size <= 63)
        assertTrue(name.startsWith("androp-"))
        assertTrue(name.endsWith("-01234567"))
    }

    @Test fun normalNamesAndExactAsciiBoundaryRemainUnchanged() {
        assertEquals("androp-My Phone", DiscoveryMetadataPolicy.serviceName("My Phone", stableId))
        assertEquals("androp-" + "a".repeat(56), DiscoveryMetadataPolicy.serviceName("a".repeat(56), stableId))
    }

    @Test fun longCommonNamesRemainDistinctAcrossStableDeviceIds() {
        val longName = "a".repeat(100)
        assertNotEquals(DiscoveryMetadataPolicy.serviceName(longName, stableId),
            DiscoveryMetadataPolicy.serviceName(longName, "abcdef01-89ab-4cde-8fab-0123456789ab"))
    }

    @Test fun serviceUnicodeIsTruncatedWithoutSplittingUtf8() {
        val name = DiscoveryMetadataPolicy.serviceName("📱مَ".repeat(100), stableId)
        assertTrue(name.toByteArray().size <= 63)
        assertEquals(name, name.toByteArray().toString(Charsets.UTF_8))
        assertFalse(name.contains('\uFFFD'))
    }

    @Test fun txtNameReservesFiveBytesForNameKey() {
        val name = DiscoveryMetadataPolicy.txtName("a".repeat(251))
        assertEquals(250, name.toByteArray().size)
        assertEquals(255, "name=$name".toByteArray().size)
    }

    @Test fun txtUnicodeStaysValidWithinByteLimit() {
        val name = DiscoveryMetadataPolicy.txtName("📱مَ".repeat(100))
        assertTrue(name.toByteArray().size <= 250)
        assertEquals(name, name.toByteArray().toString(Charsets.UTF_8))
        assertFalse(name.contains('\uFFFD'))
    }

    @Test fun controlsAndEmptyNamesCannotInvalidateDnsRecords() {
        assertEquals("ABC", DiscoveryMetadataPolicy.txtName("A\u0000B\nC"))
        assertEquals("Android", DiscoveryMetadataPolicy.txtName(" \n\u0000 "))
        assertEquals("Android", DiscoveryMetadataPolicy.txtName(null))
    }

    @Test fun malformedSurrogateIsDroppedWithoutAffectingAdjacentText() {
        assertEquals("AB", DiscoveryMetadataPolicy.txtName("A\uD800B"))
    }
}
