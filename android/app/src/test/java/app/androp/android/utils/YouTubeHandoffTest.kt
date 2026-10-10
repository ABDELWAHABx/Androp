package app.androp.android.utils

import org.junit.Assert.*
import org.junit.Test

class YouTubeHandoffTest {
    @Test fun videoFormsAndTimestampsArePreserved() {
        for (url in listOf(
            "https://www.youtube.com/watch?v=abcdefghijk&t=1m23s",
            "https://youtu.be/abcdefghijk?start=83",
            "https://m.youtube.com/shorts/abcdefghijk?time_continue=83",
            "https://youtube.com/live/abcdefghijk#t=83"
        )) assertEquals(url, YouTubeHandoff.extract("Watch this: ($url)."))
        assertEquals("https://youtu.be/abcdefghijk?t=5", YouTubeHandoff.extract("youtu.be/abcdefghijk?t=5"))
    }
    @Test fun unsupportedAndLookalikeUrlsAreRejected() {
        for (url in listOf(
            "https://youtube.com.evil.test/watch?v=abcdefghijk",
            "https://evilyoutube.com/watch?v=abcdefghijk",
            "https://evil.test/youtu.be/abcdefghijk",
            "https://evil.test@youtube.com/watch?v=abcdefghijk",
            "https://youtube.com:8443/watch?v=abcdefghijk",
            "https://youtube.com/playlist?list=abcdefghijk",
            "https://youtube.com/watch?list=abcdefghijk",
            "javascript:youtube.com/watch?v=abcdefghijk"
        )) assertNull(url, YouTubeHandoff.extract(url))
    }
}
