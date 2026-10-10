package app.androp.android.utils

import java.io.ByteArrayInputStream
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Test

class WakeupHttpHeadersTest {
    private fun read(value: String) = WakeupHttpHeaders.readContentLength(ByteArrayInputStream(value.toByteArray())) {}

    @Test fun acceptsBoundedNormalRequest() {
        assertEquals(120, read("Host: local\r\nContent-Length: 120\r\n\r\n"))
        assertEquals(0, read("Host: local\r\n\r\n"))
    }
    @Test(expected = IOException::class) fun rejectsDuplicateLengths() { read("Content-Length: 1\r\nContent-Length: 9\r\n\r\n") }
    @Test(expected = IOException::class) fun rejectsNegativeLength() { read("Content-Length: -1\r\n\r\n") }
    @Test(expected = IOException::class) fun rejectsOversizedBody() { read("Content-Length: 16385\r\n\r\n") }
    @Test(expected = IOException::class) fun rejectsUnboundedHeaderCount() { read("X: a\r\n".repeat(65) + "\r\n") }
    @Test(expected = IOException::class) fun rejectsAggregateOversizedHeaders() { read(("X: " + "a".repeat(8_000) + "\r\n").repeat(5) + "\r\n") }
    @Test(expected = IOException::class) fun rejectsTruncatedHeaders() { read("Content-Length: 1\r\n") }
    @Test(expected = IOException::class) fun rejectsChunkedEncoding() { read("Transfer-Encoding: chunked\r\n\r\n") }
    @Test(expected = java.net.SocketTimeoutException::class) fun enforcesDeadlineBeforeReading() {
        WakeupHttpHeaders.readContentLength(ByteArrayInputStream("\r\n".toByteArray())) {
            throw java.net.SocketTimeoutException("deadline")
        }
    }
}
