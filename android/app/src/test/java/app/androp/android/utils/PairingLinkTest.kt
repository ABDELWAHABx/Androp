package app.androp.android.utils

import org.junit.Assert.*
import org.junit.Test

class PairingLinkTest {
    @Test fun malformedExternalLinksDoNotCrashOrCreateConnections() {
        listOf(null, "androp://192.168.1.5:nope", "androp://host:0", "androp://host:65536",
            "androp://host", "androp://user@host:6997", "https://host:6997",
            "androp://host:6997?name=%ZZ").forEach { assertNull(it, PairingLink.parse(it)) }
    }

    @Test fun readsLegacyQrAndStandardQuerySeparators() {
        val legacy = PairingLink.parse("androp://192.168.1.5:6997?name=My%20Mac?plus=true?key=YWJj==")!!
        val standard = PairingLink.parse("androp://192.168.1.5:6997?name=My%20Mac&plus=true&key=YWJj==")!!
        assertEquals(legacy, standard)
        assertEquals("My Mac", legacy.name)
        assertEquals("YWJj==", legacy.key)
        assertEquals(6997, legacy.port)
    }

    @Test fun supportsBracketedIpv6AndRejectsOverlongData() {
        assertNotNull(PairingLink.parse("androp://[fd00::1]:6997?name=Mac"))
        assertNull(PairingLink.parse("androp://host:6997?name=" + "a".repeat(8_192)))
    }
}
