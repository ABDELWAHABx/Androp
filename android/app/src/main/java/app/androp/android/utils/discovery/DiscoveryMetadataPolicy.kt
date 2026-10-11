package app.androp.android.utils.discovery

/** DNS-SD limits apply to UTF-8 bytes, including the service prefix and TXT key. */
internal object DiscoveryMetadataPolicy {
    fun serviceName(name: String?, stableId: String): String {
        val candidate = "androp-${displayName(name)}"
        if (candidate.toByteArray(Charsets.UTF_8).size <= 63) return candidate
        val id = stableId.lowercase().filter { it in "0123456789abcdef" }.take(8)
        val suffix = if (id.isEmpty()) "" else "-$id"
        return utf8Prefix(candidate, 63 - suffix.length) + suffix
    }

    fun txtName(name: String?): String = utf8Prefix(displayName(name), 250)

    private fun displayName(name: String?): String {
        val cleaned = buildString {
            val value = name.orEmpty()
            var offset = 0
            while (offset < value.length) {
                val codePoint = value.codePointAt(offset)
                offset += Character.charCount(codePoint)
                if (!Character.isISOControl(codePoint) && codePoint !in 0xD800..0xDFFF) appendCodePoint(codePoint)
            }
        }.trim()
        return cleaned.ifEmpty { "Android" }
    }

    private fun utf8Prefix(value: String, limit: Int): String = buildString {
        var used = 0
        var offset = 0
        while (offset < value.length) {
            val codePoint = value.codePointAt(offset)
            val encoded = String(Character.toChars(codePoint))
            val bytes = encoded.toByteArray(Charsets.UTF_8).size
            if (used + bytes > limit) break
            append(encoded)
            used += bytes
            offset += Character.charCount(codePoint)
        }
    }
}
