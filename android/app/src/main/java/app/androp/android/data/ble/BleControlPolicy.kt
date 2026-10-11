package app.androp.android.data.ble

/** Small authenticated messages only. Bulk transfers and cursor streams require Wi-Fi/USB. */
object BleControlPolicy {
    const val MAX_CONTROL_BYTES = 64 * 1024
    private val incoming = setOf("macInfo", "macPowerControlResponse", "macMediaControlResponse",
        "mediaControl", "volumeControl", "callControl", "notificationAction", "toggleNowPlaying",
        "macVolume", "modifierStatus", "phoneHotspotControl", "status", "remoteControlStatus")
    private val outgoing = setOf("macMediaControl", "notificationActionResponse", "dismissalResponse",
        "mediaControlResponse", "callControlResponse", "call_event", "call_progress", "phoneHotspotState")
    fun acceptsIncoming(type: String, bytes: Int) = bytes in 1..MAX_CONTROL_BYTES && type in incoming
    fun acceptsOutgoing(type: String, bytes: Int) = bytes in 1..MAX_CONTROL_BYTES && type in outgoing
    fun acceptsRemoteAction(action: String) = action in setOf("mouse_move", "mouse_scroll", "mouse_click", "keypress", "type", "arrow_up", "arrow_down",
        "arrow_left", "arrow_right", "enter", "space", "escape", "lock_screen", "screensaver",
        "brightness_up", "brightness_down", "media_play_pause", "media_next", "media_prev", "vol_up", "vol_down", "vol_mute", "vol_set")
    fun clipboardRetryMillis(bytes: Int, wifi: Boolean): Long =
        if (wifi) 4_000L else (8_000L + bytes.coerceAtLeast(0).toLong() * 8).coerceAtMost(60_000L)
    fun clipboardWaitMillis(bytes: Int, wifi: Boolean): Long = clipboardRetryMillis(bytes, wifi) * 3 + 5_000L
}
