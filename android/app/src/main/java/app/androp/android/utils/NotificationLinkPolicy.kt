package app.androp.android.utils

/**
 * Pure rules for the optional deep link sent with a mirrored notification.
 *
 * Android never exposes the target of another app's contentIntent, so the only
 * links available are those an app visibly put in the notification (URL spans or
 * plain text) and references that map onto a public web page (Reddit's r/ and u/).
 */
object NotificationLinkPolicy {
    /** Reserved action name: fire the notification's own contentIntent on the phone. */
    const val OPEN_ON_PHONE_ACTION = "androp.openOnPhone"
    const val MAX_URL_LENGTH = 1024

    private val urlPattern = Regex("""(?i)\b(?:https?://|www\.)[^\s<>"'`]+""")
    private val redditReference = Regex("""(?<![\w/])/?([ru])/([A-Za-z0-9_]{2,21})(?![\w/])""")
    private val redditPackages = setOf("com.reddit.frontpage")

    /**
     * Explicit links win over links in text, which win over app references.
     * Returns null when nothing usable was found.
     */
    fun extract(packageName: String, spanUrls: List<String>, texts: List<String?>): String? {
        spanUrls.firstNotNullOfOrNull(::sanitize)?.let { return it }
        val visible = texts.filterNotNull().filter { it.isNotBlank() }
        visible.firstNotNullOfOrNull { text ->
            urlPattern.findAll(text).firstNotNullOfOrNull { sanitize(trimTrailing(it.value)) }
        }?.let { return it }
        if (packageName in redditPackages) {
            visible.firstNotNullOfOrNull { redditReference.find(it) }?.let { match ->
                val (kind, name) = match.destructured
                return if (kind == "r") "https://www.reddit.com/r/$name" else "https://www.reddit.com/user/$name"
            }
        }
        return null
    }

    /** Only bounded http(s) URLs with a host are forwarded; the Mac opens them in a browser. */
    fun sanitize(raw: String?): String? {
        val value = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val url = if (value.startsWith("www.", ignoreCase = true)) "https://$value" else value
        if (url.length > MAX_URL_LENGTH || url.any { it.isWhitespace() || it.isISOControl() }) return null
        val scheme = url.substringBefore("://", "").lowercase()
        if (scheme != "http" && scheme != "https") return null
        val authority = url.substringAfter("://").substringBefore('/').substringBefore('?').substringBefore('#')
        // Credentials make a link read as one site while opening another.
        if ('@' in authority) return null
        val host = authority.substringBefore(':')
        if (host.isEmpty() || !host.contains('.') || host.startsWith('.') || host.endsWith('.')) return null
        return url
    }

    /** Sentence punctuation and unbalanced closing brackets are not part of a link. */
    private fun trimTrailing(match: String): String {
        var url = match
        while (url.isNotEmpty()) {
            val last = url.last()
            url = when {
                last in ".,;:!?" -> url.dropLast(1)
                last == ')' && url.count { it == '(' } < url.count { it == ')' } -> url.dropLast(1)
                last == ']' && url.count { it == '[' } < url.count { it == ']' } -> url.dropLast(1)
                else -> return url
            }
        }
        return url
    }
}
