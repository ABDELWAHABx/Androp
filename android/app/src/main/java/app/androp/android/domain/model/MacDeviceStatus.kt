package app.androp.android.domain.model

data class MacDeviceStatus(
    val name: String = "Unknown",
    val battery: MacBattery,
    val isPaired: Boolean,
    val music: MacMusicInfo,
    val lidClosed: Boolean? = null,
    val keepAwakeEnabled: Boolean? = null,
    val keepAwakeActive: Boolean = false,
    val keepAwakeReason: String? = null,
    val powerError: String? = null,
    val closedLidOverrideEnabled: Boolean? = null,
    val closedLidOverrideActive: Boolean? = null,
    val closedLidOverrideSupported: Boolean? = null
)

data class MacBattery(
    val level: Int,
    val isCharging: Boolean
)

data class MacMusicInfo(
    val isPlaying: Boolean,
    val title: String,
    val artist: String,
    val volume: Int,
    val isMuted: Boolean,
    val albumArt: String,
    val likeStatus: String,
    val elapsedTime: Long = 0L,
    val duration: Long = 0L,
    val timestamp: String? = null,
    val playbackRate: Double = 1.0
)
