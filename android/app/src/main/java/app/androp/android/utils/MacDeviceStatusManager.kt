package app.androp.android.utils

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import android.util.Log
import app.androp.android.data.ble.BleGattServer
import app.androp.android.data.local.DataStoreManager
import app.androp.android.domain.model.MacBattery
import app.androp.android.domain.model.MacDeviceStatus
import app.androp.android.domain.model.MacMusicInfo
import app.androp.android.service.MacMediaPlayerService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

object MacDeviceStatusManager {
    private const val TAG = "MacDeviceStatusManager"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var statusJob: Job? = null
    private var decodedArtwork = ""
    private val batteryBroadcastLock = Any()
    private val batteryBroadcast = BatteryBroadcastPolicy()

    private val _macDeviceStatus = MutableStateFlow<MacDeviceStatus?>(null)
    val macDeviceStatus: StateFlow<MacDeviceStatus?> = _macDeviceStatus.asStateFlow()

    private val _albumArt = MutableStateFlow<Bitmap?>(null)
    val albumArt: StateFlow<Bitmap?> = _albumArt.asStateFlow()

    fun updateBatteryStatus(context: Context, level: Int, isCharging: Boolean) {
        val current = _macDeviceStatus.value
        updateStatus(
            context = context,
            name = current?.name ?: "Unknown",
            batteryLevel = level,
            isCharging = isCharging,
            isPaired = current?.isPaired ?: true,
            isPlaying = current?.music?.isPlaying ?: false,
            title = current?.music?.title ?: "",
            artist = current?.music?.artist ?: "",
            volume = current?.music?.volume ?: 0,
            isMuted = current?.music?.isMuted ?: false,
            albumArt = null, // keep current
            likeStatus = current?.music?.likeStatus ?: "none",
            elapsedTime = current?.music?.elapsedTime ?: 0L,
            duration = current?.music?.duration ?: 0L,
            timestamp = current?.music?.timestamp,
            playbackRate = current?.music?.playbackRate ?: 1.0
        )
    }

    fun updateMacStatus(context: Context, name: String) {
        val current = _macDeviceStatus.value
        updateStatus(
            context = context,
            name = name,
            batteryLevel = current?.battery?.level ?: -1,
            isCharging = current?.battery?.isCharging ?: false,
            isPaired = current?.isPaired ?: true,
            isPlaying = current?.music?.isPlaying ?: false,
            title = current?.music?.title ?: "",
            artist = current?.music?.artist ?: "",
            volume = current?.music?.volume ?: 0,
            isMuted = current?.music?.isMuted ?: false,
            albumArt = null, // keep current
            likeStatus = current?.music?.likeStatus ?: "none",
            elapsedTime = current?.music?.elapsedTime ?: 0L,
            duration = current?.music?.duration ?: 0L,
            timestamp = current?.music?.timestamp,
            playbackRate = current?.music?.playbackRate ?: 1.0
        )
    }

    fun updateMusicStatus(
        context: Context,
        isPlaying: Boolean,
        title: String,
        artist: String,
        volume: Int,
        isMuted: Boolean,
        likeStatus: String,
        albumArt: String? = null
    ) {
        val current = _macDeviceStatus.value
        updateStatus(
            context = context,
            name = current?.name ?: "Unknown",
            batteryLevel = current?.battery?.level ?: -1,
            isCharging = current?.battery?.isCharging ?: false,
            isPaired = current?.isPaired ?: true,
            isPlaying = isPlaying,
            title = title,
            artist = artist,
            volume = volume,
            isMuted = isMuted,
            albumArt = albumArt,
            likeStatus = likeStatus,
            elapsedTime = current?.music?.elapsedTime ?: 0L,
            duration = current?.music?.duration ?: 0L,
            timestamp = current?.music?.timestamp,
            playbackRate = current?.music?.playbackRate ?: 1.0
        )
    }

    @Synchronized
    fun updateStatus(
        context: Context,
        name: String,
        batteryLevel: Int,
        isCharging: Boolean,
        isPaired: Boolean,
        isPlaying: Boolean,
        title: String,
        artist: String,
        volume: Int,
        isMuted: Boolean,
        albumArt: String?,
        likeStatus: String,
        elapsedTime: Long = 0L,
        duration: Long = 0L,
        timestamp: String? = null,
        playbackRate: Double = 1.0,
        forceMediaRefresh: Boolean = false,
        lidClosed: Boolean? = null,
        keepAwakeEnabled: Boolean? = null,
        keepAwakeActive: Boolean? = null,
        keepAwakeReason: String? = null,
        powerError: String? = null,
        closedLidOverrideEnabled: Boolean? = null,
        closedLidOverrideActive: Boolean? = null,
        closedLidOverrideSupported: Boolean? = null
    ) {
        try {
            val previous = _macDeviceStatus.value
            val hasMedia = RemoteMediaPolicy.hasSession(isPlaying, title, artist)
            val effectiveAlbumArt = if (hasMedia) albumArt ?: previous?.music?.albumArt ?: "" else ""

            val macBattery = MacBattery(level = batteryLevel, isCharging = isCharging)
            val macMusicInfo = MacMusicInfo(
                isPlaying = isPlaying,
                title = title,
                artist = artist,
                volume = volume,
                isMuted = isMuted,
                albumArt = effectiveAlbumArt,
                likeStatus = likeStatus,
                elapsedTime = elapsedTime,
                duration = duration,
                timestamp = timestamp,
                playbackRate = playbackRate
            )

            val status = MacDeviceStatus(
                name = name,
                battery = macBattery,
                isPaired = isPaired,
                music = macMusicInfo,
                lidClosed = lidClosed ?: previous?.lidClosed,
                keepAwakeEnabled = keepAwakeEnabled ?: previous?.keepAwakeEnabled,
                keepAwakeActive = keepAwakeActive ?: previous?.keepAwakeActive ?: false,
                keepAwakeReason = if (lidClosed != null || keepAwakeEnabled != null || keepAwakeActive != null) {
                    keepAwakeReason?.takeIf { it.isNotBlank() }
                } else previous?.keepAwakeReason,
                powerError = if (powerError != null) {
                    powerError.takeIf { it.isNotBlank() }?.take(256)
                } else previous?.powerError,
                closedLidOverrideEnabled = closedLidOverrideEnabled ?: previous?.closedLidOverrideEnabled,
                closedLidOverrideActive = closedLidOverrideActive ?: previous?.closedLidOverrideActive,
                closedLidOverrideSupported = closedLidOverrideSupported ?: previous?.closedLidOverrideSupported
            )

            if (status == previous && !forceMediaRefresh) return
            _macDeviceStatus.value = status
            if (!hasMedia) _albumArt.value = null

            // Supersede stale updates: a slow settings/artwork read must not resurrect playback.
            statusJob?.cancel()
            statusJob = scope.launch {
                val bitmap = if (effectiveAlbumArt != decodedArtwork) {
                    withContext(Dispatchers.Default) { decodeAlbumArt(effectiveAlbumArt) }
                } else _albumArt.value
                _albumArt.value = bitmap
                decodedArtwork = effectiveAlbumArt
                val ds = DataStoreManager(context)
                val isMediaControlsEnabled = ds.getMacMediaControlsEnabled().first()
                val isConnected =
                    WebSocketUtil.isConnected() || BleGattServer.isAnyAuthenticated()
                val isEssentialsEnabled = ds.getEssentialsConnectionEnabled().first()
                val isPaused = ds.isAppPaused().first()

                if (!isPaused && !BackgroundWorkController.isPaused && isConnected && isMediaControlsEnabled && hasMedia) {
                    MacMediaPlayerService.startMacMedia(
                        context,
                        title,
                        artist,
                        isPlaying,
                        bitmap,
                        elapsedTime,
                        duration,
                        timestamp,
                        playbackRate,
                        volume,
                        name
                    )
                    Log.d(TAG, "Started/Updated Mac media player service")
                } else {
                    MacMediaPlayerService.stopMacMedia(context)
                    if (!isMediaControlsEnabled) {
                        Log.d(
                            TAG,
                            "Stopped Mac media player service - controls explicitly disabled by user"
                        )
                    } else if (!isConnected) {
                        Log.d(TAG, "Stopped Mac media player service - device disconnected")
                    } else {
                        Log.d(TAG, "Stopped Mac media player service - no active media")
                    }
                }

                // Broadcast to Essentials if enabled
                if (!isPaused && isEssentialsEnabled) {
                    broadcastToEssentials(context, batteryLevel, isCharging, isConnected)
                } else if (!isEssentialsEnabled) {
                    synchronized(batteryBroadcastLock) { batteryBroadcast.reset() }
                }
            }

            Log.d(
                TAG,
                "Mac device status updated - Playing: $isPlaying, Title: $title, Artist: $artist"
            )
        } catch (e: Exception) {
            Log.e(TAG, "Error updating Mac device status: ${e.message}")
        }
    }

    /** Power-only updates preserve playback and do not restart the native media service. */
    @Synchronized
    fun updatePowerStatus(
        lidClosed: Boolean?,
        keepAwakeEnabled: Boolean?,
        keepAwakeActive: Boolean?,
        keepAwakeReason: String?,
        powerError: String? = null,
        closedLidOverrideEnabled: Boolean? = null,
        closedLidOverrideActive: Boolean? = null,
        closedLidOverrideSupported: Boolean? = null
    ) {
        if (lidClosed == null && keepAwakeEnabled == null && keepAwakeActive == null && powerError == null &&
            closedLidOverrideEnabled == null && closedLidOverrideActive == null && closedLidOverrideSupported == null) return
        val previous = _macDeviceStatus.value ?: MacDeviceStatus(
            battery = MacBattery(-1, false), isPaired = true,
            music = MacMusicInfo(false, "", "", 50, false, "", "none")
        )
        _macDeviceStatus.value = previous.copy(
            lidClosed = lidClosed ?: previous.lidClosed,
            keepAwakeEnabled = keepAwakeEnabled ?: previous.keepAwakeEnabled,
            keepAwakeActive = keepAwakeActive ?: previous.keepAwakeActive,
            keepAwakeReason = if (lidClosed != null || keepAwakeEnabled != null || keepAwakeActive != null || keepAwakeReason != null) {
                keepAwakeReason?.takeIf { it.isNotBlank() }
            } else previous.keepAwakeReason,
            powerError = if (powerError != null) powerError.takeIf { it.isNotBlank() }?.take(256) else previous.powerError,
            closedLidOverrideEnabled = closedLidOverrideEnabled ?: previous.closedLidOverrideEnabled,
            closedLidOverrideActive = closedLidOverrideActive ?: previous.closedLidOverrideActive,
            closedLidOverrideSupported = closedLidOverrideSupported ?: previous.closedLidOverrideSupported
        )
    }

    /** Reconciles a cached session when the app becomes visible or native controls are re-enabled. */
    fun refreshNativePlayer(context: Context) {
        val status = _macDeviceStatus.value ?: return
        val music = status.music
        updateStatus(context, status.name, status.battery.level, status.battery.isCharging,
            status.isPaired, music.isPlaying, music.title, music.artist, music.volume, music.isMuted,
            null, music.likeStatus, music.elapsedTime, music.duration, music.timestamp, music.playbackRate,
            forceMediaRefresh = true)
    }

    private fun decodeAlbumArt(base64String: String): Bitmap? {
        return try {
            if (base64String.isNotEmpty()) {
                val decodedBytes = Base64.decode(base64String, Base64.DEFAULT)
                val boundsOptions = BitmapFactory.Options().apply {
                    inJustDecodeBounds = true
                }
                BitmapFactory.decodeByteArray(decodedBytes, 0, decodedBytes.size, boundsOptions)

                val targetSize = 512
                var inSampleSize = 1
                if (boundsOptions.outHeight > targetSize || boundsOptions.outWidth > targetSize) {
                    val halfHeight = boundsOptions.outHeight / 2
                    val halfWidth = boundsOptions.outWidth / 2
                    while ((halfHeight / inSampleSize) >= targetSize || (halfWidth / inSampleSize) >= targetSize) {
                        inSampleSize *= 2
                    }
                }

                val decodeOptions = BitmapFactory.Options().apply {
                    this.inSampleSize = inSampleSize
                }
                BitmapFactory.decodeByteArray(decodedBytes, 0, decodedBytes.size, decodeOptions)
            } else {
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error decoding album art: ${e.message}")
            null
        }
    }

    private fun broadcastToEssentials(
        context: Context,
        level: Int,
        isCharging: Boolean,
        isConnected: Boolean,
        force: Boolean = false
    ) {
        synchronized(batteryBroadcastLock) {
            val state = BatteryBroadcastPolicy.State(level, isCharging, isConnected)
            if (!batteryBroadcast.shouldPublish(state, force)) return
            try {
                val intent =
                    android.content.Intent("com.sameerasw.essentials.action.UPDATE_MAC_BATTERY").apply {
                        putExtra("level", level)
                        putExtra("isCharging", isCharging)
                        putExtra("lastUpdated", System.currentTimeMillis())
                        putExtra("isConnected", isConnected)
                        setPackage("com.sameerasw.essentials")
                    }
                context.sendBroadcast(intent, "com.sameerasw.permission.ESSENTIALS_AIRSYNC_BRIDGE")
                batteryBroadcast.didPublish(state)
                Log.d(TAG, "Broadcasted Mac status to Essentials (connected: $isConnected)")
            } catch (e: Exception) {
                Log.e(TAG, "Error broadcasting to Essentials: ${e.message}")
            }
        }
    }

    private var connectionListener: ((Boolean) -> Unit)? = null

    fun startMonitoring(context: Context) {
        if (connectionListener != null) return // Already monitoring

        Log.d(TAG, "Starting connection monitoring for MacDeviceStatusManager")
        connectionListener = { isConnected ->
            if (!isConnected && !BleGattServer.isAnyAuthenticated()) cleanup(context)
            scope.launch {
                val ds = DataStoreManager(context)
                val isEssentialsEnabled = ds.getEssentialsConnectionEnabled().first()
                if (isEssentialsEnabled) {
                    if (!isConnected && !BleGattServer.isAnyAuthenticated()) {
                        broadcastToEssentials(context, -1, false, false)
                    }
                }
            }
        }
        WebSocketUtil.registerConnectionStatusListener(connectionListener!!)
    }

    fun stopMonitoring() {
        connectionListener?.let {
            WebSocketUtil.unregisterConnectionStatusListener(it)
        }
        connectionListener = null
    }

    fun broadcastCurrentStatus(context: Context) {
        scope.launch {
            try {
                val settings = DataStoreManager.getInstance(context)
                if (!settings.getEssentialsConnectionEnabled().first() ||
                    settings.isAppPaused().first() || BackgroundWorkController.isPaused) return@launch
                // Check current state
                val isConnected = WebSocketUtil.isConnected() || BleGattServer.isAnyAuthenticated()
                val currentStatus = _macDeviceStatus.value

                if (isConnected && currentStatus != null) {
                    // Send actual data with connected = true
                    broadcastToEssentials(
                        context,
                        currentStatus.battery.level,
                        currentStatus.battery.isCharging,
                        true,
                        force = true
                    )
                } else {
                    // Send connected = false (no data needed, or stale)
                    broadcastToEssentials(context, -1, false, false, force = true)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error broadcasting current status: ${e.message}")
            }
        }
    }

    @Synchronized
    fun cleanup(context: Context? = null) {
        try {
            statusJob?.cancel()
            statusJob = null
            decodedArtwork = ""
            context?.let { MacMediaPlayerService.stopMacMedia(it) }
            _albumArt.value = null
            _macDeviceStatus.value = null
            Log.d(TAG, "Mac device status cleaned up")

            // If context is provided, broadcast disconnection to Essentials
            if (context != null) {
                scope.launch {
                    val ds = DataStoreManager(context)
                    val isEssentialsEnabled = ds.getEssentialsConnectionEnabled().first()
                    if (isEssentialsEnabled) {
                        broadcastToEssentials(context, -1, false, false)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error cleaning up: ${e.message}")
        }
    }
}
