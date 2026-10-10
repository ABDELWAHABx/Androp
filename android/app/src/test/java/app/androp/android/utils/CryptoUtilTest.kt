package app.androp.android.utils

import java.util.Base64
import org.junit.Assert.*
import org.junit.Test

class CryptoUtilTest {
    private fun key(value: Int) = CryptoUtil.decodeKey(Base64.getEncoder().encodeToString(ByteArray(32) { value.toByte() }))

    @Test fun unicodeRoundTripUsesFreshNonces() {
        val secret = key(7)
        val text = "Clipboard · مرحبا · https://youtu.be/abc?t=42"
        val first = CryptoUtil.encryptMessage(text, secret)!!
        val second = CryptoUtil.encryptMessage(text, secret)!!
        assertNotEquals(first, second)
        assertEquals(text, CryptoUtil.decryptMessage(first, secret))
        assertEquals(text, CryptoUtil.decryptMessage(second, secret))
    }

    @Test fun invalidAuthenticationNeverReturnsPlaintext() {
        val secret = key(7)
        val encrypted = CryptoUtil.encryptMessage("private clipboard", secret)!!
        assertNull(CryptoUtil.decryptMessage(encrypted, key(8)))
        val bytes = Base64.getDecoder().decode(encrypted)
        bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
        assertNull(CryptoUtil.decryptMessage(Base64.getEncoder().encodeToString(bytes), secret))
        assertNull(CryptoUtil.decryptMessage("{\"type\":\"macInfo\"}", secret))
        assertNull(CryptoUtil.decryptMessage("AA==", secret))
    }

    @Test fun keyWhitespaceIsAcceptedAndInvalidLengthRejected() {
        val encoded = Base64.getEncoder().encodeToString(ByteArray(32) { 7 })
        assertArrayEquals(key(7).encoded, CryptoUtil.decodeKey("\n$encoded\n").encoded)
        assertThrows(IllegalArgumentException::class.java) { CryptoUtil.decodeKey("AA==") }
    }
}
