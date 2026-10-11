package app.androp.android.utils

import com.google.gson.JsonParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationLinkPolicyTest {
    private val reddit = "com.reddit.frontpage"

    @Test fun explicitSpanLinkWinsOverText() {
        assertEquals("https://example.com/post/1", NotificationLinkPolicy.extract("app",
            listOf("intent://bad", "https://example.com/post/1"), listOf("see https://other.com")))
    }

    @Test fun firstUrlInTextIsExtractedWithoutSentencePunctuation() {
        assertEquals("https://news.example.com/a?id=4", NotificationLinkPolicy.extract("app", emptyList(),
            listOf(null, "", "Read this: https://news.example.com/a?id=4.")))
        assertEquals("https://en.wikipedia.org/wiki/Foo_(bar)", NotificationLinkPolicy.extract("app", emptyList(),
            listOf("(https://en.wikipedia.org/wiki/Foo_(bar))")))
        assertEquals("https://www.example.com/x", NotificationLinkPolicy.extract("app", emptyList(),
            listOf("Go to www.example.com/x!")))
    }

    @Test fun redditReferencesMapToPublicPagesOnlyForReddit() {
        assertEquals("https://www.reddit.com/r/androiddev", NotificationLinkPolicy.extract(reddit, emptyList(),
            listOf("Trending in r/androiddev", "Some post title")))
        assertEquals("https://www.reddit.com/user/spez", NotificationLinkPolicy.extract(reddit, emptyList(),
            listOf("u/spez replied to your comment")))
        assertEquals("https://www.reddit.com/r/Kotlin", NotificationLinkPolicy.extract(reddit, emptyList(),
            listOf("New in /r/Kotlin")))
        assertNull(NotificationLinkPolicy.extract("com.example.chat", emptyList(), listOf("Trending in r/androiddev")))
        assertNull(NotificationLinkPolicy.extract(reddit, emptyList(), listOf("our/androiddev", "a r/b", "Hot post")))
    }

    @Test fun realLinkInRedditNotificationWinsOverReference() {
        assertEquals("https://www.reddit.com/r/x/comments/abc/t/", NotificationLinkPolicy.extract(reddit, emptyList(),
            listOf("r/x", "https://www.reddit.com/r/x/comments/abc/t/")))
    }

    @Test fun onlyBoundedWebUrlsAreAccepted() {
        assertNull(NotificationLinkPolicy.sanitize("javascript:alert(1)"))
        assertNull(NotificationLinkPolicy.sanitize("file:///etc/passwd"))
        assertNull(NotificationLinkPolicy.sanitize("https://"))
        assertNull(NotificationLinkPolicy.sanitize("https://localhost/x"))
        assertNull(NotificationLinkPolicy.sanitize("https://exa mple.com"))
        assertNull(NotificationLinkPolicy.sanitize("https://example.com/" + "a".repeat(NotificationLinkPolicy.MAX_URL_LENGTH)))
        assertEquals("HTTPS://Example.com", NotificationLinkPolicy.sanitize(" HTTPS://Example.com "))
        assertEquals("https://example.com:8443/a", NotificationLinkPolicy.sanitize("https://example.com:8443/a"))
        // Credentials make a link read as one site while opening another.
        assertNull(NotificationLinkPolicy.sanitize("https://reddit.com@evil.example/a"))
        assertNull(NotificationLinkPolicy.extract("app", emptyList(), listOf("No links here, e.g. r/foo")))
    }

    @Test fun openOnPhoneActionNameMatchesTheMac() {
        // Mirrored by NotificationOpenPolicy.openOnPhoneAction in the Mac app.
        assertEquals("androp.openOnPhone", NotificationLinkPolicy.OPEN_ON_PHONE_ACTION)
    }

    @Test fun notificationJsonCarriesOptionalLinkFields() {
        fun data(url: String?, canOpen: Boolean?) = JsonParser.parseString(JsonUtil.createNotificationJson(
            "id", "t", "b", "App", "pkg", actions = emptyList(), url = url, canOpenOnPhone = canOpen
        )).asJsonObject.getAsJsonObject("data")
        val full = data("https://example.com/a?b=\"c\"", true)
        assertEquals("https://example.com/a?b=\"c\"", full.get("url").asString)
        assertTrue(full.get("canOpenOnPhone").asBoolean)
        val legacy = data(null, null)
        assertFalse(legacy.has("url"))
        assertFalse(legacy.has("canOpenOnPhone"))
    }
}
