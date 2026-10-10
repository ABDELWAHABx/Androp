package app.androp.android.utils

import java.net.URLDecoder
import java.security.MessageDigest
import java.security.SecureRandom

/** An ephemeral mount capability. Never persist or log the token or complete DAV URLs. */
internal object WebDavAccessPolicy {
    fun newToken(): String = ByteArray(32).also { SecureRandom().nextBytes(it) }
        .joinToString("") { "%02x".format(it.toInt() and 255) }

    fun prefix(token: String): String = "/.androp/$token/"

    fun relativePath(rawPath: String, token: String?): String? {
        if (token == null || !token.matches(Regex("[0-9a-f]{64}"))) return null
        val parts = rawPath.split('/', limit = 4)
        if (parts.size != 4 || parts[0].isNotEmpty() || parts[1] != ".androp") return null
        if (!MessageDigest.isEqual(parts[2].toByteArray(Charsets.UTF_8), token.toByteArray(Charsets.UTF_8))) return null
        return try {
            val path = URLDecoder.decode(parts[3].replace("+", "%2B"), "UTF-8").trimEnd('/')
            // Canonical containment is also checked against storageRoot; reject ambiguous
            // segments here so Finder cannot navigate outside this capability URL prefix.
            if (path.contains('\u0000') || path.contains('\\') || path.split('/').any { it == "." || it == ".." }) null else path
        } catch (_: IllegalArgumentException) { null }
    }

    fun supportsDepth(depth: String?): Boolean = depth == null || depth == "0" || depth == "1"
}
