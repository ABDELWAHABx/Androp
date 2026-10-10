package app.androp.android.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.ComponentName
import android.media.AudioManager
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.os.Build
import android.os.IBinder
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.media.VolumeProviderCompat
import app.androp.android.utils.BackgroundWorkController
import app.androp.android.utils.MacDeviceStatusManager
import app.androp.android.utils.RemoteMediaPolicy
import app.androp.android.utils.RemotePlaybackPublicationPolicy
import app.androp.android.utils.RemotePlaybackSnapshot
import org.json.JSONObject
import app.androp.android.MainActivity
import app.androp.android.R
import app.androp.android.utils.WebSocketUtil

class MacMediaPlayerService : Service() {
    companion object {
        const val ACTION_START_MAC_MEDIA = "START_MAC_MEDIA"
        const val ACTION_STOP_MAC_MEDIA = "STOP_MAC_MEDIA"
        const val ACTION_UPDATE_MAC_MEDIA = "UPDATE_MAC_MEDIA"

        const val EXTRA_TITLE = "title"
        const val EXTRA_ARTIST = "artist"
        const val EXTRA_IS_PLAYING = "is_playing"
        const val EXTRA_ALBUM_ART = "album_art"
        const val EXTRA_ELAPSED_TIME = "elapsed_time"
        const val EXTRA_DURATION = "duration"
        const val EXTRA_TIMESTAMP = "timestamp"
        const val EXTRA_PLAYBACK_RATE = "playback_rate"
        const val EXTRA_VOLUME = "volume"
        const val EXTRA_MAC_NAME = "mac_name"
        private const val EXTRA_SHARED_FOREGROUND = "shared_foreground"

        private const val TAG = "MacMediaPlayerService"
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_ID = "mac_media_channel"

        @Volatile private var serviceInstance: MacMediaPlayerService? = null
        @Volatile private var pendingAlbumArt: Bitmap? = null

        fun startMacMedia(
            context: android.content.Context,
            title: String,
            artist: String,
            isPlaying: Boolean,
            albumArt: Bitmap?,
            elapsedTime: Long = 0L,
            duration: Long = 0L,
            timestamp: String? = null,
            playbackRate: Double = 1.0,
            volume: Int = 50,
            macName: String = "Mac"
        ) {
            if (BackgroundWorkController.isPaused) return
            if (!RemoteMediaPolicy.hasSession(isPlaying, title, artist)) {
                stopMacMedia(context)
                return
            }
            val running = serviceInstance
            if (running != null && !running.stopping) {
                // Update the existing session directly instead of issuing a service start for each position.
                val apply = Runnable {
                    if (serviceInstance === running && !running.stopping && !BackgroundWorkController.isPaused) {
                        running.currentAlbumArt = albumArt
                        running.currentMacName = macName
                        running.updateRemoteVolume(volume)
                        running.startMacMediaSession(title, artist, isPlaying,
                            elapsedTime, duration, timestamp, playbackRate)
                    }
                }
                if (Looper.myLooper() == Looper.getMainLooper()) apply.run()
                else Handler(Looper.getMainLooper()).post(apply)
                return
            }
            val intent = Intent(context, MacMediaPlayerService::class.java).apply {
                action = ACTION_START_MAC_MEDIA
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_ARTIST, artist)
                putExtra(EXTRA_IS_PLAYING, isPlaying)
                putExtra(EXTRA_ELAPSED_TIME, elapsedTime)
                putExtra(EXTRA_DURATION, duration)
                putExtra(EXTRA_TIMESTAMP, timestamp)
                putExtra(EXTRA_PLAYBACK_RATE, playbackRate)
                putExtra(EXTRA_VOLUME, volume)
                putExtra(EXTRA_MAC_NAME, macName)
            }
            pendingAlbumArt = albumArt
            try {
                if (AirSyncService.isRunning()) {
                    // Android 12+ can reject starting another FGS from the background. The sync
                    // FGS already keeps our process foreground: use a regular session service and
                    // a normal MediaStyle notification under that existing lifetime.
                    intent.putExtra(EXTRA_SHARED_FOREGROUND, true)
                    context.startService(intent)
                } else {
                    intent.putExtra(EXTRA_SHARED_FOREGROUND, false)
                    context.startForegroundService(intent)
                }
            } catch (e: RuntimeException) {
                // Android can restrict foreground starts from a background BLE callback.
                Log.w(TAG, "Media controls cannot start in the current app state", e)
            }
        }

        fun updateMacMedia(
            context: android.content.Context,
            title: String,
            artist: String,
            isPlaying: Boolean,
            albumArt: Bitmap?,
            elapsedTime: Long = 0L,
            duration: Long = 0L,
            timestamp: String? = null,
            playbackRate: Double = 1.0,
            volume: Int = 50,
            macName: String = "Mac"
        ) {
            // Share the safe startup path so updates cannot create a background-only service.
            startMacMedia(context, title, artist, isPlaying, albumArt,
                elapsedTime, duration, timestamp, playbackRate, volume, macName)
        }

        fun dispatchMediaButton(intent: Intent): Boolean {
            if (BackgroundWorkController.isPaused) return false
            val session = serviceInstance?.mediaSession ?: return false
            if (!session.isActive) return false
            val key = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT)
            } ?: return false
            return session.controller.dispatchMediaButtonEvent(key)
        }

        fun stopMacMedia(context: android.content.Context) {
            pendingAlbumArt = null
            serviceInstance?.stopping = true
            serviceInstance = null
            // Stopping idle media must never create a new service or a phantom notification.
            context.stopService(Intent(context, MacMediaPlayerService::class.java))
        }
    }

    private var mediaSession: MediaSessionCompat? = null
    private var currentAlbumArt: Bitmap? = null
    private var currentMacName = "Mac"
    private var remoteVolume: VolumeProviderCompat? = null
    private var volumeBeforeMute = 50
    private var foregroundStarted = false
    private var usesSharedForeground = false
    private var notificationPublished = false
    @Volatile private var stopping = false
    private data class MetadataKey(val title: String, val artist: String, val duration: Long,
        val artwork: Bitmap?, val generation: Int?, val macName: String)
    private var metadataKey: MetadataKey? = null
    private data class NotificationKey(val metadata: MetadataKey?, val isPlaying: Boolean)
    private var notificationKey: NotificationKey? = null

    override fun onCreate() {
        super.onCreate()
        serviceInstance = this
        createNotificationChannel()
        try {
            val receiver = ComponentName(this, MacMediaButtonReceiver::class.java)
            val mediaButtonIntent = PendingIntent.getBroadcast(this, 0,
                Intent(Intent.ACTION_MEDIA_BUTTON).setComponent(receiver),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            mediaSession = MediaSessionCompat(this, "AndropMacMedia", receiver, mediaButtonIntent).apply {
                setFlags(MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS)
                setSessionActivity(createSessionActivity())
                setExtras(Bundle().apply {
                    putBoolean("android.media.session.extra.SLOT_RESERVATION_SKIP_TO_PREV", true)
                    putBoolean("android.media.session.extra.SLOT_RESERVATION_SKIP_TO_NEXT", true)
                })
                setCallback(object : MediaSessionCompat.Callback() {
                    override fun onPlay() {
                        if (sendMacMediaControl("play")) updatePlaybackState(true)
                    }

                    override fun onPause() {
                        if (sendMacMediaControl("pause")) updatePlaybackState(false)
                    }

                    override fun onSkipToNext() {
                        sendMacMediaControl("next")
                    }

                    override fun onSkipToPrevious() {
                        sendMacMediaControl("previous")
                    }

                    override fun onSeekTo(pos: Long) {
                        val duration = this@MacMediaPlayerService.mediaSession?.controller?.metadata
                            ?.getLong(MediaMetadataCompat.METADATA_KEY_DURATION) ?: 0L
                        if (!WebSocketUtil.isConnected() || duration <= 0) return
                        val position = RemoteMediaPolicy.boundPosition(pos, duration)
                        if (sendMacMediaControl("seekTo", position)) {
                            val playing = this@MacMediaPlayerService.mediaSession?.controller?.playbackState?.state == PlaybackStateCompat.STATE_PLAYING
                            val speed = this@MacMediaPlayerService.mediaSession?.controller?.playbackState?.playbackSpeed?.toDouble() ?: 1.0
                            updatePlaybackState(playing, position, playbackRate = speed, force = true)
                        }
                    }

                    override fun onStop() {
                        sendMacMediaControl("stop")
                        stopMacMediaSession()
                    }
                })
            }
            updateRemoteVolume(MacDeviceStatusManager.macDeviceStatus.value?.music?.volume ?: 50)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create MediaSession in onCreate: ${e.message}")
        }
        Log.d(TAG, "MacMediaPlayerService created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        Log.d(TAG, "onStartCommand: action=$action")

        if (BackgroundWorkController.isPaused || action == ACTION_STOP_MAC_MEDIA || action == null) {
            stopMacMediaSession()
            return START_NOT_STICKY
        }
        val isMetadataUpdate = action == ACTION_START_MAC_MEDIA || action == ACTION_UPDATE_MAC_MEDIA
        if (isMetadataUpdate) {
            stopping = false
            serviceInstance = this
            usesSharedForeground = intent.getBooleanExtra(EXTRA_SHARED_FOREGROUND, usesSharedForeground)
            if (usesSharedForeground && !AirSyncService.isRunning()) {
                stopMacMediaSession()
                return START_NOT_STICKY
            }
            currentAlbumArt = pendingAlbumArt
            currentMacName = intent.getStringExtra(EXTRA_MAC_NAME) ?: "Mac"
            updateRemoteVolume(intent.getIntExtra(EXTRA_VOLUME, 50))
            val title = intent.getStringExtra(EXTRA_TITLE).orEmpty()
            val artist = intent.getStringExtra(EXTRA_ARTIST).orEmpty()
            val playing = intent.getBooleanExtra(EXTRA_IS_PLAYING, false)
            if (!RemoteMediaPolicy.hasSession(playing, title, artist)) {
                stopMacMediaSession()
                return START_NOT_STICKY
            }
        } else if (mediaSession?.isActive != true) {
            // Ignore actions from a dismissed/expired notification.
            stopMacMediaSession()
            return START_NOT_STICKY
        }

        when (action) {
            ACTION_START_MAC_MEDIA -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: ""
                val artist = intent.getStringExtra(EXTRA_ARTIST) ?: ""
                val isPlaying = intent.getBooleanExtra(EXTRA_IS_PLAYING, false)
                val elapsedTime = intent.getLongExtra(EXTRA_ELAPSED_TIME, 0L)
                val duration = intent.getLongExtra(EXTRA_DURATION, 0L)
                val timestamp = intent.getStringExtra(EXTRA_TIMESTAMP)
                val playbackRate = intent.getDoubleExtra(EXTRA_PLAYBACK_RATE, 1.0)

                startMacMediaSession(
                    title,
                    artist,
                    isPlaying,
                    elapsedTime,
                    duration,
                    timestamp,
                    playbackRate
                )
            }

            ACTION_UPDATE_MAC_MEDIA -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: ""
                val artist = intent.getStringExtra(EXTRA_ARTIST) ?: ""
                val isPlaying = intent.getBooleanExtra(EXTRA_IS_PLAYING, false)
                val elapsedTime = intent.getLongExtra(EXTRA_ELAPSED_TIME, 0L)
                val duration = intent.getLongExtra(EXTRA_DURATION, 0L)
                val timestamp = intent.getStringExtra(EXTRA_TIMESTAMP)
                val playbackRate = intent.getDoubleExtra(EXTRA_PLAYBACK_RATE, 1.0)

                startMacMediaSession(
                    title,
                    artist,
                    isPlaying,
                    elapsedTime,
                    duration,
                    timestamp,
                    playbackRate
                )
            }
            // Handle media control actions from notification buttons
            "MAC_MEDIA_play" -> {
                if (sendMacMediaControl("play")) updatePlaybackState(true)
            }

            "MAC_MEDIA_pause" -> {
                if (sendMacMediaControl("pause")) updatePlaybackState(false)
            }

            "MAC_MEDIA_next" -> {
                sendMacMediaControl("next")
            }

            "MAC_MEDIA_previous" -> {
                sendMacMediaControl("previous")
            }

            "MAC_MEDIA_stop" -> {
                sendMacMediaControl("stop")
                stopMacMediaSession()
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Mac Media Player",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Mac media playback controls"
            setShowBadge(false)
            setSound(null, null)
        }

        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.createNotificationChannel(channel)
    }

    private fun startMacMediaSession(
        title: String,
        artist: String,
        isPlaying: Boolean,
        elapsedTime: Long = 0L,
        duration: Long = 0L,
        timestamp: String? = null,
        playbackRate: Double = 1.0
    ) {
        try {
            updateMediaMetadata(title, artist, duration)
            updatePlaybackState(isPlaying, elapsedTime, timestamp, playbackRate)
            if (mediaSession?.isActive != true) mediaSession?.isActive = true

            publishNotification(title, artist, isPlaying)

            Log.d(TAG, "Mac media session started as foreground service")
        } catch (e: Exception) {
            Log.e(TAG, "Error starting Mac media session: ${e.message}")
            stopMacMediaSession()
        }
    }

    private fun updateMediaMetadata(title: String, artist: String, duration: Long = 0L) {
        val key = MetadataKey(title, artist, duration, currentAlbumArt,
            currentAlbumArt?.takeUnless { it.isRecycled }?.generationId, currentMacName)
        if (key == metadataKey) return
        metadataKey = key
        val metadataBuilder = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, artist)
            .putString(MediaMetadataCompat.METADATA_KEY_ALBUM, "On $currentMacName")
            .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_TITLE, title)
            .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_SUBTITLE, artist)
            .putString(MediaMetadataCompat.METADATA_KEY_DISPLAY_DESCRIPTION, "On $currentMacName")
            .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, duration.coerceAtLeast(0))

        currentAlbumArt?.let { bitmap ->
            metadataBuilder.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, bitmap)
        }

        mediaSession?.setMetadata(metadataBuilder.build())
    }

    private fun updatePlaybackState(
        isPlaying: Boolean,
        elapsedTime: Long = -1L,
        timestamp: String? = null,
        playbackRate: Double = 1.0,
        force: Boolean = false
    ) {
        val state =
            if (isPlaying) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED
        val duration = mediaSession?.controller?.metadata
            ?.getLong(MediaMetadataCompat.METADATA_KEY_DURATION) ?: 0L
        val seekAction = if (WebSocketUtil.isConnected() && duration > 0) PlaybackStateCompat.ACTION_SEEK_TO else 0L
        val actions = seekAction or PlaybackStateCompat.ACTION_PLAY_PAUSE or
                PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                PlaybackStateCompat.ACTION_STOP or PlaybackStateCompat.ACTION_PLAY or PlaybackStateCompat.ACTION_PAUSE

        val previousState = mediaSession?.controller?.playbackState
        var position = if (elapsedTime >= 0) elapsedTime else {
            RemoteMediaPolicy.projectLocalPosition(previousState?.position ?: 0L,
                android.os.SystemClock.elapsedRealtime() - (previousState?.lastPositionUpdateTime ?: 0L),
                previousState?.state == PlaybackStateCompat.STATE_PLAYING,
                previousState?.playbackSpeed?.toDouble() ?: 1.0, duration)
        }
        if (isPlaying && !timestamp.isNullOrEmpty()) {
            val sinceReport = runCatching {
                System.currentTimeMillis() - java.time.Instant.parse(timestamp).toEpochMilli()
            }.getOrDefault(0L)
            position = RemoteMediaPolicy.projectPosition(position, sinceReport, true, playbackRate, duration)
        }

        val now = android.os.SystemClock.elapsedRealtime()
        val boundedPosition = RemoteMediaPolicy.boundPosition(position, duration)
        val speed = RemoteMediaPolicy.playbackSpeed(isPlaying, playbackRate)
        val previous = previousState?.let { RemotePlaybackSnapshot(
            it.state == PlaybackStateCompat.STATE_PLAYING, it.position, it.playbackSpeed,
            it.actions, it.lastPositionUpdateTime) }
        val next = RemotePlaybackSnapshot(isPlaying, boundedPosition, speed, actions, now)
        if (force || RemotePlaybackPublicationPolicy.shouldPublish(previous, next, duration)) mediaSession?.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setState(state, boundedPosition, speed, now)
                .setActions(actions)
                .build()
        )
        if (notificationPublished) {
            val metadata = mediaSession?.controller?.metadata
            publishNotification(metadata?.getString(MediaMetadataCompat.METADATA_KEY_TITLE).orEmpty(),
                metadata?.getString(MediaMetadataCompat.METADATA_KEY_ARTIST).orEmpty(), isPlaying)
        }
    }

    private fun createSessionActivity(): PendingIntent = PendingIntent.getActivity(this, 0,
        Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun publishNotification(title: String, artist: String, isPlaying: Boolean) {
        val key = NotificationKey(metadataKey, isPlaying)
        if (notificationPublished && key == notificationKey) return
        val notification = createMediaNotification(title, artist, isPlaying)
        if (!usesSharedForeground && !foregroundStarted) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else startForeground(NOTIFICATION_ID, notification)
            foregroundStarted = true
        } else getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
        notificationPublished = true
        notificationKey = key
    }

    private fun updateRemoteVolume(volume: Int) {
        val level = volume.coerceIn(0, 100)
        if (level > 0) volumeBeforeMute = level
        if (remoteVolume == null) {
            remoteVolume = object : VolumeProviderCompat(VolumeProviderCompat.VOLUME_CONTROL_ABSOLUTE, 100, level) {
                override fun onSetVolumeTo(volume: Int) {
                    val requested = volume.coerceIn(0, 100)
                    if (sendRemoteVolume("vol_set", requested)) setCurrentVolume(requested)
                }
                override fun onAdjustVolume(direction: Int) {
                    if (direction == AudioManager.ADJUST_MUTE || direction == AudioManager.ADJUST_UNMUTE ||
                        direction == AudioManager.ADJUST_TOGGLE_MUTE) {
                        val target = when (direction) {
                            AudioManager.ADJUST_MUTE -> 0
                            AudioManager.ADJUST_UNMUTE -> if (currentVolume == 0) volumeBeforeMute else currentVolume
                            else -> if (currentVolume > 0) 0 else volumeBeforeMute
                        }
                        if (currentVolume > 0) volumeBeforeMute = currentVolume
                        if (sendRemoteVolume("vol_set", target)) setCurrentVolume(target)
                        return
                    }
                    val action = when (direction) {
                        AudioManager.ADJUST_RAISE -> "vol_up"
                        AudioManager.ADJUST_LOWER -> "vol_down"
                        else -> return
                    }
                    if (sendRemoteVolume(action)) {
                        val change = if (direction == AudioManager.ADJUST_RAISE) 6 else -6
                        setCurrentVolume((currentVolume + change).coerceIn(0, 100))
                        if (currentVolume > 0) volumeBeforeMute = currentVolume
                    }
                }
            }
            mediaSession?.setPlaybackToRemote(remoteVolume!!)
        } else if (remoteVolume?.currentVolume != level) remoteVolume?.setCurrentVolume(level)
    }

    private fun sendRemoteVolume(action: String, value: Int? = null): Boolean {
        if (BackgroundWorkController.isPaused) return false
        val data = JSONObject().put("action", action)
        value?.let { data.put("value", it) }
        return WebSocketUtil.sendMessage(JSONObject().put("type", "remoteControl").put("data", data).toString())
    }

    private fun createMediaNotification(
        title: String,
        artist: String,
        isPlaying: Boolean
    ): Notification {
        val activityIntent = Intent(this, MainActivity::class.java)
        val activityPendingIntent = PendingIntent.getActivity(
            this, 0, activityIntent, PendingIntent.FLAG_IMMUTABLE
        )

        // Create media control actions
        val prevAction = NotificationCompat.Action(
            R.drawable.outline_skip_previous_24,
            "Previous",
            createMediaActionPendingIntent("previous")
        )

        val playPauseAction = NotificationCompat.Action(
            if (isPlaying) R.drawable.outline_pause_24 else R.drawable.outline_play_arrow_24,
            if (isPlaying) "Pause" else "Play",
            createMediaActionPendingIntent(if (isPlaying) "pause" else "play")
        )

        val nextAction = NotificationCompat.Action(
            R.drawable.outline_skip_next_24,
            "Next",
            createMediaActionPendingIntent("next")
        )

        val dynamicIcon = app.androp.android.utils.DeviceIconResolver.getLastDeviceIconRes(this)
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(dynamicIcon)
            .setContentTitle(title.ifEmpty { "Mac Media Player" })
            .setContentText(artist.ifEmpty { "On $currentMacName" })
            .setSubText("On $currentMacName")
            .setSilent(true)
            .setContentIntent(activityPendingIntent)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setOngoing(isPlaying)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .addAction(prevAction)
            .addAction(playPauseAction)
            .addAction(nextAction)

        currentAlbumArt?.let { bitmap ->
            builder.setLargeIcon(bitmap)
        }

        // This is the key: MediaStyle with session token makes it show in Quick Settings
        val mediaStyle = androidx.media.app.NotificationCompat.MediaStyle()
            .setMediaSession(mediaSession?.sessionToken)
            .setShowActionsInCompactView(0, 1, 2) // Show all three actions

        builder.setStyle(mediaStyle)

        return builder.build()
    }

    private fun createMediaActionPendingIntent(action: String): PendingIntent {
        val intent = Intent(this, MacMediaPlayerService::class.java).apply {
            this.action = "MAC_MEDIA_$action"
        }
        return PendingIntent.getService(
            this, action.hashCode(), intent, PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun stopMacMediaSession() {
        try {
            // Release in onDestroy: a new START arriving before teardown can reuse the session.
            stopping = true
            if (serviceInstance === this) serviceInstance = null
            mediaSession?.isActive = false
            foregroundStarted = false
            notificationPublished = false
            notificationKey = null
            stopForeground(STOP_FOREGROUND_REMOVE)
            getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
            stopSelf()
            Log.d(TAG, "Mac media session stopped")
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping Mac media session: ${e.message}")
        }
    }

    private fun sendMacMediaControl(action: String, positionMs: Long? = null): Boolean {
        if (BackgroundWorkController.isPaused ||
            (!WebSocketUtil.isConnected() && !app.androp.android.data.ble.BleGattServer.isAnyAuthenticated())) return false
        val data = JSONObject().put("action", action)
        positionMs?.let { data.put("positionMs", it) }
        return WebSocketUtil.sendMessage(JSONObject().put("type", "macMediaControl").put("data", data).toString())
    }

    fun updateAlbumArt(albumArt: Bitmap?) {
        currentAlbumArt = albumArt
        // Update existing notification if service is running
        mediaSession?.let {
            val metadata = it.controller.metadata
            if (metadata != null) {
                val title = metadata.getString(MediaMetadataCompat.METADATA_KEY_TITLE) ?: ""
                val artist = metadata.getString(MediaMetadataCompat.METADATA_KEY_ARTIST) ?: ""
                val isPlaying =
                    it.controller.playbackState?.state == PlaybackStateCompat.STATE_PLAYING
                val duration = metadata.getLong(MediaMetadataCompat.METADATA_KEY_DURATION)
                val speed = it.controller.playbackState?.playbackSpeed?.toDouble() ?: 1.0

                // Artwork arriving late must not rewind playback to the last position anchor.
                startMacMediaSession(title, artist, isPlaying, -1L, duration, null, speed)
            }
        }
    }

    private fun releaseMediaSession() {
        mediaSession?.isActive = false
        mediaSession?.setCallback(null)
        mediaSession?.release()
        mediaSession = null
        currentAlbumArt = null
        remoteVolume = null
        metadataKey = null
        notificationKey = null
        foregroundStarted = false
        notificationPublished = false
    }

    override fun onDestroy() {
        if (serviceInstance === this) {
            serviceInstance = null
            pendingAlbumArt = null
        }
        releaseMediaSession()
        stopForeground(STOP_FOREGROUND_REMOVE)
        getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
        super.onDestroy()
        Log.d(TAG, "MacMediaPlayerService destroyed")
    }
}
