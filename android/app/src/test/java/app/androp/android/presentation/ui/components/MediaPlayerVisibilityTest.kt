package app.androp.android.presentation.ui.components

import app.androp.android.domain.model.MacMusicInfo
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaPlayerVisibilityTest {
    private fun music(title: String = "", artist: String = "", playing: Boolean = false) =
        MacMusicInfo(playing, title, artist, 50, false, "", "", duration = 0)

    @Test fun emptyConnectionDoesNotReservePlayerSpace() {
        assertFalse(hasVisibleMacMedia(null))
        assertFalse(hasVisibleMacMedia(music()))
        assertFalse(hasVisibleMacMedia(music("  ", "\n")))
        assertFalse(hasVisibleMacMedia(music("?", "?")))
        assertFalse(hasVisibleMacMedia(music("Nothing Playing")))
    }

    @Test fun pausedTrackKeepsCompactControlsAvailable() {
        assertTrue(hasVisibleMacMedia(music("A song")))
        assertTrue(hasVisibleMacMedia(music(artist = "A station")))
    }

    @Test fun liveUntitledMediaRemainsControllable() {
        assertTrue(hasVisibleMacMedia(music(playing = true)))
    }
}
