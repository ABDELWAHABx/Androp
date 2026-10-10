package app.androp.android.utils

import com.google.gson.JsonParser
import org.junit.Assert.assertEquals
import org.junit.Test

class JsonUtilTest {
    @Test fun clipboardRoundTripsBackslashesAndControlCharacters() {
        val text = "C:\\new\\file\t\"quoted\"\n\r\b\u0000 😀"
        val data = JsonParser.parseString(JsonUtil.createClipboardUpdateJson(text))
            .asJsonObject.getAsJsonObject("data")
        assertEquals(text, data.get("text").asString)
    }

    @Test fun notificationsPreserveFormattingAndQuotedTitles() {
        val title = "Meet \"Sam\""
        val body = "columns:  one    two\tthree\u0001"
        val json = JsonUtil.toSingleLine(JsonUtil.createNotificationJson(
            "id\"", title, body, "App", "package", actions = listOf("Reply\tNow" to "reply")
        ))
        val data = JsonParser.parseString(json).asJsonObject.getAsJsonObject("data")
        assertEquals(title, data.get("title").asString)
        assertEquals(body, data.get("body").asString)
        assertEquals("id\"", data.get("id").asString)
    }

    @Test fun quotedDeviceNamesAndMediaMetadataRemainValidJson() {
        val name = "My \"Phone\"\\Android"
        val device = JsonParser.parseString(JsonUtil.createDeviceInfoJson(name, "127.0.0.1", 6997, "1"))
            .asJsonObject.getAsJsonObject("data")
        assertEquals(name, device.get("name").asString)
        val status = JsonParser.parseString(JsonUtil.createDeviceStatusJson(
            50, false, true, true, name, "Artist\tName", 50, false, null, likeStatus = "none"
        )).asJsonObject.getAsJsonObject("data").getAsJsonObject("music")
        assertEquals(name, status.get("title").asString)
        assertEquals("Artist\tName", status.get("artist").asString)
    }
}
