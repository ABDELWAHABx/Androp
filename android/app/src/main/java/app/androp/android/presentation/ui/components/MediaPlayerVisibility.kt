package app.androp.android.presentation.ui.components

import app.androp.android.domain.model.MacMusicInfo

/** A connection alone is not a media session. Paused, titled media stays available. */
internal fun hasVisibleMacMedia(music: MacMusicInfo?): Boolean {
    if (music == null) return false
    if (music.isPlaying) return true
    fun String.isMetadata(): Boolean = trim().let {
        it.isNotEmpty() && it != "?" && !it.equals("Nothing Playing", ignoreCase = true)
    }
    return music.title.isMetadata() || music.artist.isMetadata()
}
