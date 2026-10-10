package app.androp.android.utils

import java.io.IOException
import java.io.InputStream

/** Caps aggregate headers and rejects ambiguous lengths before allocating a request body. */
internal object WakeupHttpHeaders {
    const val MAX_BODY = 16_384
    fun readContentLength(input: InputStream, checkDeadline: () -> Unit): Int {
        var total = 0
        var count = 0
        var contentLength: Int? = null
        while (true) {
            val line = StringBuilder()
            while (true) {
                checkDeadline()
                val next = input.read()
                if (next < 0) throw IOException("Incomplete HTTP headers")
                if (++total > 32_768 || line.length > 8_192) throw IOException("HTTP headers too large")
                if (next == 10) break
                if (next != 13) line.append(next.toChar())
            }
            if (line.isEmpty()) return contentLength ?: 0
            if (++count > 64) throw IOException("Too many HTTP headers")
            val separator = line.indexOf(":")
            if (separator <= 0) throw IOException("Invalid HTTP header")
            when (line.substring(0, separator).lowercase()) {
                "content-length" -> {
                    if (contentLength != null) throw IOException("Duplicate Content-Length")
                    val value = line.substring(separator + 1).trim().toIntOrNull()
                    if (value == null || value !in 0..MAX_BODY) throw IOException("Invalid Content-Length")
                    contentLength = value
                }
                "transfer-encoding" -> throw IOException("Transfer-Encoding is not supported")
            }
        }
    }
}
