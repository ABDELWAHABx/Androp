package app.androp.android.utils

import java.net.URI

/** Extract only a public YouTube video URL; retain its original query/fragment timestamps. */
object YouTubeHandoff {
    private val candidates = Regex("(?i)(?:https?://)?(?:(?:www|m|music)\\.)?(?:youtube\\.com|youtu\\.be)/[^\\s<>\\\"']+")
    private val hosts = setOf("youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be")
    private val videoId = Regex("[A-Za-z0-9_-]{1,64}")
    fun extract(text: String): String? {
        if (text.length > 64 * 1024) return null
        for (match in candidates.findAll(text)) {
            // A domain substring inside a hostile hostname is not a YouTube link.
            if (match.range.first > 0 && text[match.range.first - 1].let { it.isLetterOrDigit() || it in "._@-/?:" }) continue
            val raw = match.value.trimEnd('.', ',', ';', ')', ']', '}')
            val normalized = if (raw.startsWith("http", ignoreCase = true)) raw else "https://$raw"
            val uri = try { URI(normalized) } catch (_: Exception) { continue }
            if (uri.scheme?.lowercase() !in setOf("http", "https") || uri.host?.lowercase() !in hosts || uri.userInfo != null || uri.port != -1) continue
            val parts = uri.path.orEmpty().trim('/').split('/')
            val valid = if (uri.host.lowercase().endsWith("youtu.be")) {
                parts.size == 1 && videoId.matches(parts[0])
            } else if (parts.size == 1 && parts[0] == "watch") {
                uri.rawQuery.orEmpty().split('&').any { it.startsWith("v=") && videoId.matches(it.removePrefix("v=")) }
            } else parts.size == 2 && parts[0] in setOf("shorts", "live") && videoId.matches(parts[1])
            if (valid) return normalized
        }
        return null
    }
}
