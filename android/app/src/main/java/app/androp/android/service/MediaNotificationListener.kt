package app.androp.android.service

import android.app.Notification
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.Rating
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.MediaSession
import android.os.Handler
import android.os.Looper
import android.media.session.PlaybackState
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import app.androp.android.data.local.DataStoreManager
import app.androp.android.domain.model.MediaInfo
import app.androp.android.utils.JsonUtil
import app.androp.android.utils.NotificationActionPolicy
import app.androp.android.utils.NotificationDismissalUtil
import app.androp.android.utils.SyncManager
import app.androp.android.utils.WebSocketUtil
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import app.androp.android.utils.BackgroundWorkController
import app.androp.android.utils.BoundedValueCache
import app.androp.android.utils.MediaArtworkCache
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

class MediaNotificationListener : NotificationListenerService() {

    companion object {
        @Volatile
        private var currentMediaInfo: MediaInfo? = null

        @Volatile
        private var serviceInstance: MediaNotificationListener? = null
        private const val TAG = "MediaNotificationListener"

        // Flag to pause media listener when receiving playing media from Mac
        @Volatile
        private var isMediaListenerPaused = false

        // New: global toggle for now playing reporting
        @Volatile
        private var isNowPlayingEnabled: Boolean = true

        // Excluded media packages
        @Volatile
        private var excludedMediaPackages: Set<String> = emptySet()

        fun isExcludedMediaPackage(context: Context, packageName: String?): Boolean =
            packageName.isNullOrBlank() || packageName == context.packageName || packageName in excludedMediaPackages

        fun setExcludedMediaPackages(packages: Set<String>) {
            excludedMediaPackages = packages
            serviceInstance?.refreshSessionObservers()
            Log.d(TAG, "Updated excluded media packages: ${packages.size} apps excluded")
        }

        fun setNowPlayingEnabled(context: Context, enabled: Boolean) {
            isNowPlayingEnabled = enabled
            if (!enabled) {
                // Clear cached media and pause listener
                currentMediaInfo = null
                serviceInstance?.mediaRefreshJob?.cancel()
                isMediaListenerPaused = true
                Log.d(TAG, "Now playing disabled: pausing media listener and clearing cache")
            } else {
                isMediaListenerPaused = false
                serviceInstance?.scheduleMediaRefresh()
                Log.d(TAG, "Now playing enabled: resuming media listener")
            }
            serviceInstance?.refreshSessionObservers()
            // Trigger a status sync to reflect change
            SyncManager.checkAndSyncDeviceStatus(context, forceSync = true)
        }

        fun hasSignificantMediaChange(old: MediaInfo?, new: MediaInfo?): Boolean {
            if (old == null && new == null) return false
            if (old == null || new == null) return true
            return old.isPlaying != new.isPlaying ||
                   old.title != new.title ||
                   old.artist != new.artist ||
                   old.albumArt != new.albumArt ||
                   old.albumArtLite != new.albumArtLite ||
                   old.durationMs != new.durationMs ||
                   old.isBuffering != new.isBuffering ||
                   old.likeStatus != new.likeStatus || hasPositionDiscontinuity(old, new)
        }

        private fun hasPositionDiscontinuity(old: MediaInfo, new: MediaInfo): Boolean {
            if (old.positionTimestampMs <= 0 || new.positionTimestampMs <= 0) return false
            val elapsed = if (old.isPlaying) {
                (new.positionTimestampMs - old.positionTimestampMs).coerceAtLeast(0)
            } else 0L
            val expected = (old.positionMs + elapsed).let {
                if (old.durationMs > 0) it.coerceAtMost(old.durationMs) else it
            }
            // Regular progress is interpolated locally; an actual seek must still sync.
            return kotlin.math.abs(new.positionMs - expected) > 1_500L
        }

        // In-memory cache of like status per track key
        private val likeStatusCache = LinkedHashMap<String, String>(32, 0.75f, true)

        // System packages to ignore
        private val SYSTEM_PACKAGES = setOf(
            "android",
            "com.android.systemui",
            "com.android.providers.downloads",
            "com.google.android.gms",
            "com.android.vending"
        )

        // Only attach like status for these media apps
        private val ALLOWED_PACKAGES = setOf(
            "com.google.android.apps.youtube.music", // YouTube Music
            "com.spotify.music" // Spotify
        )

        fun getInstance(): MediaNotificationListener? {
            return serviceInstance
        }

        fun getMediaInfo(context: Context): MediaInfo {
            // Respect global toggle; if disabled, return empty media
            if (!isNowPlayingEnabled || BackgroundWorkController.isPaused) {
                return MediaInfo(false, "", "", null, null, 0L, 0L, 0L, false, "none")
            }
            return try {
                val mediaSessionManager =
                    context.getSystemService(MEDIA_SESSION_SERVICE) as MediaSessionManager

                val componentName = ComponentName(context, MediaNotificationListener::class.java)

                val activeSessions = try {
                    mediaSessionManager.getActiveSessions(componentName)
                } catch (e: SecurityException) {
                    Log.w(TAG, "SecurityException getting active sessions: ${e.message}")
                    emptyList()
                }

                // Log.d(TAG, "Found ${activeSessions.size} active media sessions")

                if (activeSessions.isNotEmpty()) {
                    for (controller in activeSessions.sortedByDescending { it.playbackState?.state == PlaybackState.STATE_PLAYING }) {
                        try {
                            if (isExcludedMediaPackage(context, controller.packageName)) {
                                continue
                            }
                        } catch (_: Exception) {
                        }

                        val metadata = controller.metadata
                        val playbackState = controller.playbackState

                        val title = metadata?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""
                        val artist = metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: ""
                        val isPlaying = playbackState?.state == PlaybackState.STATE_PLAYING
                        val durationMs =
                            metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L
                        val positionTimestampMs = System.currentTimeMillis()
                        val progressSinceUpdate = if (isPlaying &&
                            playbackState.lastPositionUpdateTime > 0) {
                            ((android.os.SystemClock.elapsedRealtime() - playbackState.lastPositionUpdateTime)
                                .coerceAtLeast(0) * playbackState.playbackSpeed).toLong()
                        } else 0L
                        val positionMs = ((playbackState?.position ?: 0L) + progressSinceUpdate)
                            .coerceAtLeast(0).let { if (durationMs > 0) it.coerceAtMost(durationMs) else it }
                        val isBuffering = when (playbackState?.state) {
                            PlaybackState.STATE_BUFFERING,
                            PlaybackState.STATE_CONNECTING -> true

                            else -> false
                        }

                        if (playbackState?.state == PlaybackState.STATE_STOPPED ||
                            playbackState?.state == PlaybackState.STATE_NONE ||
                            (title.isBlank() && artist.isBlank() && !isPlaying && !isBuffering)) continue

                        val albumArtBitmap =
                            metadata?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
                                ?: metadata?.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)

                        val (albumArtBase64, albumArtLiteBase64) = MediaArtworkCache.encode(albumArtBitmap)

                        // Log.d(TAG, "Media session - Title: $title, Artist: $artist, Playing: $isPlaying, State: ${playbackState?.state}")

                        // Determine like status; apply app filter and strict positive-only like detection
                        val (detectedStatus, source) = determineLikeStatusWithSource(
                            context,
                            controller
                        )
                        var likeStatus = detectedStatus

                        // If filtered by app, force none and skip cache
                        if (source == "appfilter") {
                            likeStatus = "none"
                        }

                        // Return the first session that has media info or is playing
                        if (title.isNotEmpty() || artist.isNotEmpty() || isPlaying) {
                            return MediaInfo(
                                isPlaying = isPlaying,
                                title = title,
                                artist = artist,
                                albumArt = albumArtBase64,
                                albumArtLite = albumArtLiteBase64,
                                durationMs = durationMs,
                                positionMs = positionMs,
                                positionTimestampMs = positionTimestampMs,
                                isBuffering = isBuffering,
                                likeStatus = likeStatus
                            )
                        }
                    }
                }

                // Log.d(TAG, "No media info found")
                MediaInfo(false, "", "", null, null, 0L, 0L, 0L, false, "none")
            } catch (e: Exception) {
                Log.e(TAG, "Error getting media info: ${e.message}")
                MediaInfo(false, "", "", null, null, 0L, 0L, 0L, false, "none")
            }
        }

        private fun determineLikeStatusWithSource(
            context: Context,
            controller: MediaController
        ): Pair<String, String> {
            // Enforce package filter first
            val pkg = controller.packageName
            if (pkg.isNullOrEmpty() || !ALLOWED_PACKAGES.contains(pkg)) {
                return "none" to "appfilter"
            }

            try {
                val md = controller.metadata
                // Prefer explicit user rating/heart/thumbs metadata if present
                val userRating: Rating? = try {
                    md?.getRating(MediaMetadata.METADATA_KEY_USER_RATING)
                } catch (_: Exception) {
                    null
                }
                val rating: Rating? = userRating ?: try {
                    md?.getRating(MediaMetadata.METADATA_KEY_RATING)
                } catch (_: Exception) {
                    null
                }
                if (rating != null) {
                    if (rating.isRated) {
                        when (rating.ratingStyle) {
                            Rating.RATING_HEART -> {
                                val liked = try {
                                    rating.hasHeart()
                                } catch (_: Exception) {
                                    false
                                }
                                Log.d(TAG, "Like from HEART rating: $liked")
                                return if (liked) "liked" to "rating" else "not_liked" to "rating"
                            }

                            Rating.RATING_THUMB_UP_DOWN -> {
                                val up = try {
                                    rating.isThumbUp
                                } catch (_: Exception) {
                                    false
                                }
                                Log.d(TAG, "Like from THUMB rating: $up")
                                return if (up) "liked" to "rating" else "not_liked" to "rating"
                            }

                            else -> Log.d(
                                TAG,
                                "Rating present but not mappable (style=${rating.ratingStyle})"
                            )
                        }
                    } else {
                        // Not rated counts as not_liked per requirement
                        Log.d(TAG, "Rating present but not rated -> not_liked")
                        return "not_liked" to "rating"
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to read metadata rating: ${e.message}")
            }

            // For allowed apps: if no positive rating, treat as not_liked
            return "not_liked" to "rating"
        }

        private fun detectLikeStatusForPackage(targetPackage: String?): String {
            val service = getInstance() ?: return "none"
            val notifs = try {
                service.activeNotifications
            } catch (_: Exception) {
                emptyArray<StatusBarNotification>()
            }
            if (notifs.isEmpty()) return "none"

            // Look for notification from the target package first, then others
            val candidates =
                notifs.filter { it.packageName == targetPackage } + notifs.filter { it.packageName != targetPackage }

            for (sbn in candidates) {
                val n = sbn.notification
                val actions = n.actions ?: continue
                // Debug log action titles and semantic actions for inspection
                try {
                    actions.forEachIndexed { idx, act ->
                        Log.d(
                            TAG,
                            "Notif action[$idx]: title='${act.title}', semantic=${act.semanticAction}"
                        )
                    }
                } catch (_: Exception) {
                }
                val status = inferLikeStatusFromActions(actions)
                if (status != null) return status
            }
            return "none"
        }

        private fun inferLikeStatusFromActions(actions: Array<Notification.Action>): String? {
            // Priority 1: explicit text indicating Unlike/Remove -> liked
            for (action in actions) {
                val title = action.title?.toString()?.lowercase()?.trim() ?: ""
                if (title.isEmpty()) continue
                if (title.contains("unlike") || title.contains("remove from liked") || title.contains(
                        "remove like"
                    ) || title == "liked"
                ) {
                    return "liked"
                }
            }
            // Priority 2: semantic thumbs up/down if titles are missing
            for (action in actions) {
                val sem = action.semanticAction
                if (sem == Notification.Action.SEMANTIC_ACTION_THUMBS_DOWN) {
                    return "liked" // apps often show "unlike" when already liked
                }
            }
            for (action in actions) {
                val title = action.title?.toString()?.lowercase()?.trim() ?: ""
                val sem = action.semanticAction
                if (title.contains("like") || title.contains("favorite") || title.contains("favourite") ||
                    title.contains("❤") || title.contains("♥") ||
                    sem == Notification.Action.SEMANTIC_ACTION_THUMBS_UP
                ) {
                    return "not_liked"
                }
            }
            return null
        }

        // Build a track key using most stable metadata available
        private fun buildTrackKey(controller: MediaController): String? {
            return try {
                val pkg = controller.packageName ?: return null
                val md = controller.metadata ?: return null
                val mediaId = md.getString(MediaMetadata.METADATA_KEY_MEDIA_ID)
                val title = md.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""
                val artist = md.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: ""
                val album = md.getString(MediaMetadata.METADATA_KEY_ALBUM) ?: ""
                val base = if (!mediaId.isNullOrEmpty()) mediaId else listOf(
                    title,
                    artist,
                    album
                ).joinToString("|")
                if (base.isBlank()) null else "$pkg|$base"
            } catch (_: Exception) {
                null
            }
        }

        private fun getCachedLikeStatusFor(controller: MediaController): String {
            val key = buildTrackKey(controller) ?: return "none"
            synchronized(likeStatusCache) {
                return likeStatusCache[key] ?: "none"
            }
        }

        private fun updateCachedLikeStatusFor(controller: MediaController, status: String) {
            val key = buildTrackKey(controller) ?: return
            synchronized(likeStatusCache) {
                likeStatusCache[key] = status
                // Trim cache to 100 entries
                if (likeStatusCache.size > 100) {
                    val it = likeStatusCache.entries.iterator()
                    if (it.hasNext()) {
                        it.next()
                        it.remove()
                    }
                }
            }
        }

        // Public helpers for other components
        fun setCachedLikeStatusForCurrent(context: Context, status: String): Boolean {
            return try {
                val msm = context.getSystemService(MEDIA_SESSION_SERVICE) as MediaSessionManager
                val componentName = ComponentName(context, MediaNotificationListener::class.java)
                val sessions = try {
                    msm.getActiveSessions(componentName)
                } catch (_: Exception) {
                    emptyList()
                }
                val controller =
                    sessions.firstOrNull { it.packageName != context.packageName &&
                        it.packageName !in excludedMediaPackages && it.playbackState?.actions != 0L } ?: return false
                updateCachedLikeStatusFor(controller, status)
                true
            } catch (_: Exception) {
                false
            }
        }

        fun refreshMonitoring() { serviceInstance?.refreshSessionObservers() }

        fun pauseMediaListener() {
            // The mirrored Mac session is excluded by package. Keep observing real phone apps,
            // including a user starting phone playback while Mac playback is still active.
        }

        fun resumeMediaListener() {
            // Don't resume if globally disabled
            if (!isNowPlayingEnabled) return
            val wasPaused = isMediaListenerPaused
            isMediaListenerPaused = false
            if (wasPaused) serviceInstance?.scheduleMediaRefresh()
            Log.d(TAG, "Media listener resumed")
        }
    }

    private val serviceJob = SupervisorJob()
    private val serviceScope = CoroutineScope(Dispatchers.IO + serviceJob)
    private lateinit var dataStoreManager: DataStoreManager

    private val workJob = SupervisorJob(serviceJob)
    private val workScope = CoroutineScope(Dispatchers.IO + workJob)
    private val sentNotifications = BoundedValueCache<String, String>(256)
    private val notificationSendMutex = Mutex()
    private var mediaRefreshJob: Job? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var listenerConnected = false
    private var activeSessionsListener: MediaSessionManager.OnActiveSessionsChangedListener? = null
    private val observedSessions = LinkedHashMap<MediaSession.Token, Pair<MediaController, MediaController.Callback>>()

    private fun refreshSessionObservers() {
        mainHandler.post {
            stopSessionObservers()
            startSessionObservers()
            scheduleMediaRefresh()
        }
    }

    private fun startSessionObservers() {
        if (!listenerConnected || BackgroundWorkController.isPaused || !isNowPlayingEnabled || activeSessionsListener != null) return
        val manager = getSystemService(MediaSessionManager::class.java)
        val component = ComponentName(this, MediaNotificationListener::class.java)
        val listener = MediaSessionManager.OnActiveSessionsChangedListener { sessions ->
            observeSessions(sessions.orEmpty())
            scheduleMediaRefresh()
        }
        try {
            manager.addOnActiveSessionsChangedListener(listener, component, mainHandler)
            activeSessionsListener = listener
            observeSessions(manager.getActiveSessions(component))
        } catch (e: SecurityException) {
            stopSessionObservers()
            Log.w(TAG, "Media session permission unavailable", e)
        }
    }

    private fun observeSessions(sessions: List<MediaController>) {
        val eligible = sessions.filter { !isExcludedMediaPackage(this, it.packageName) }
        val tokens = eligible.map { it.sessionToken }.toSet()
        observedSessions.keys.filter { it !in tokens }.forEach { token ->
            observedSessions.remove(token)?.let { (controller, callback) ->
                runCatching { controller.unregisterCallback(callback) }
            }
        }
        eligible.forEach { controller ->
            if (controller.sessionToken in observedSessions) return@forEach
            val callback = object : MediaController.Callback() {
                override fun onPlaybackStateChanged(state: PlaybackState?) { scheduleMediaRefresh() }
                override fun onMetadataChanged(metadata: MediaMetadata?) { scheduleMediaRefresh() }
                override fun onSessionDestroyed() {
                    observedSessions.remove(controller.sessionToken)
                    runCatching { controller.unregisterCallback(this) }
                    scheduleMediaRefresh()
                }
            }
            controller.registerCallback(callback, mainHandler)
            observedSessions[controller.sessionToken] = controller to callback
        }
    }

    private fun stopSessionObservers() {
        observedSessions.values.forEach { (controller, callback) ->
            runCatching { controller.unregisterCallback(callback) }
        }
        observedSessions.clear()
        activeSessionsListener?.let { listener ->
            runCatching { getSystemService(MediaSessionManager::class.java).removeOnActiveSessionsChangedListener(listener) }
        }
        activeSessionsListener = null
    }

    override fun onCreate() {
        super.onCreate()
        dataStoreManager = DataStoreManager(this)
        serviceInstance = this
        serviceScope.launch {
            dataStoreManager.isAppPaused().collect { paused ->
                mainHandler.post {
                    if (paused) stopSessionObservers() else startSessionObservers()
                }
                if (paused) {
                    workJob.cancelChildren()
                    currentMediaInfo = null
                    sentNotifications.clear()
                    MediaArtworkCache.clear()
                }
            }
        }

        // Load the persisted now playing setting
        serviceScope.launch {
            try {
                val enabled = dataStoreManager.getSendNowPlayingEnabled().first()
                isNowPlayingEnabled = enabled
                isMediaListenerPaused = !enabled
                refreshSessionObservers()
                Log.d(TAG, "Initialized now playing setting: $enabled")
            } catch (_: Exception) {
            }
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        listenerConnected = true
        startSessionObservers()
        Log.d(TAG, "Notification listener connected - Ready to sync notifications")
        // Start AirSyncService scanning when listener connects (effectively on boot)
        try {
            AirSyncService.startScanning(applicationContext)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start AirSyncService from listener", e)
        }

        // Re-register notifications that were already in the shade before this
        // process started. Without this, actions and dismissals coming from the
        // client fail with "not found" for every notification that predates the
        // listener connecting. The persisted key->id mapping recovers the exact
        // ID the client already holds even when the notification was updated
        // since (its postTime — embedded in generated IDs — changes on update,
        // while sbn.key stays stable).
        try {
            val currentKeys = mutableSetOf<String>()
            activeNotifications?.forEach { sbn ->
                currentKeys.add(sbn.key)
                NotificationDismissalUtil.registerNotification(sbn)
            }
            NotificationDismissalUtil.prunePersistedMappings(currentKeys)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to restore active notifications on listener connect", e)
        }

        scheduleMediaRefresh()
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        listenerConnected = false
        stopSessionObservers()
        Log.d(TAG, "Notification listener disconnected")

        workJob.cancelChildren()
        currentMediaInfo = null
        sentNotifications.clear()
        MediaArtworkCache.clear()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        super.onNotificationPosted(sbn)
        if (BackgroundWorkController.isPaused || !WebSocketUtil.isConnected()) {
            return
        }
        sbn?.let { notification ->
            if (notification.packageName == packageName) return@let
            Log.d(
                TAG,
                "Notification posted: ${notification.packageName} - ${
                    notification.notification?.extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString()
                }"
            )

            scheduleMediaRefresh()

            // Always process notification for sync (non-media notifications)
            processNotificationForSync(notification)
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        sbn?.let(::handleNotificationRemoval)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification, rankingMap: RankingMap) {
        handleNotificationRemoval(sbn)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification, rankingMap: RankingMap, reason: Int) {
        // Calling super delegates through the other overloads and sends the same removal repeatedly.
        handleNotificationRemoval(sbn)
    }

    private fun handleNotificationRemoval(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return
        Log.d(TAG, "Notification removed: ${sbn.packageName}")

        // A queued removal for an older instance must not clear a replacement with the same key.
        val replacementIsActive = try {
            getActiveNotifications(arrayOf(sbn.key))?.any { it.key == sbn.key } == true
        } catch (_: Exception) { false }
        if (replacementIsActive) return
        sentNotifications.remove(sbn.key)
        // Capture and clear synchronously: queued removal jobs must not delete a later repost,
        // and duplicate callback overloads must not echo the raw Android key to the Mac.
        val id = NotificationDismissalUtil.getIdForSbn(sbn) ?: return
        val suppressed = NotificationDismissalUtil.consumeSuppressed(id)
        NotificationDismissalUtil.removeFromCaches(id)
        if (BackgroundWorkController.isPaused || !WebSocketUtil.isConnected()) return
        scheduleMediaRefresh()
        if (suppressed) return
        workScope.launch {
            if (BackgroundWorkController.isPaused) return@launch
            WebSocketUtil.sendMessage(JsonUtil.toSingleLine(
                JsonUtil.createNotificationUpdateJson(id, dismissed = true, action = "dismiss")))
        }
    }

    private fun processNotificationForSync(sbn: StatusBarNotification) {
        workScope.launch {
            notificationSendMutex.withLock {
            try {
                if (BackgroundWorkController.isPaused || !WebSocketUtil.isConnected()) return@launch
                if (!isCurrentNotification(sbn)) return@launch
                // Skip notifications from AirSync itself to prevent feedback loops
                if (sbn.packageName == packageName) {
                    return@launch
                }

                // Skip Phone app notifications - call handling is done via BroadcastReceiver
                if (sbn.packageName == "com.google.android.dialer") {
                    Log.d(
                        TAG,
                        "Skipping Phone app notification - call handling via BroadcastReceiver"
                    )
                    return@launch
                }

                // Check if notification sync is enabled
                val isSyncEnabled = dataStoreManager.getNotificationSyncEnabled().first()
                if (!isSyncEnabled) {
                    Log.d(TAG, "Notification sync is disabled, skipping notification")
                    return@launch
                }

                // Check if this specific app is enabled for notifications
                val notificationApps = dataStoreManager.getNotificationApps().first()
                val appSettings = notificationApps.find { it.packageName == sbn.packageName }

                // If app settings exist and it's disabled, skip
                if (appSettings != null && !appSettings.isEnabled) {
                    Log.d(TAG, "App ${sbn.packageName} is disabled for notifications, skipping")
                    return@launch
                }

                // Skip system notifications and media-only notifications
                if (shouldSkipNotification(sbn)) {
                    Log.d(TAG, "Skipping notification from ${sbn.packageName}")
                    return@launch
                }

                val notification = sbn.notification
                val extras = notification.extras

                val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
                val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
                val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()

                // Use big text if available, otherwise use regular text
                val body = bigText?.takeIf { it.isNotEmpty() } ?: text

                // Get app name from package name
                val appName = getAppNameFromPackage(sbn.packageName)

                // Only sync if we have meaningful content
                if (title.isNotEmpty() || body.isNotEmpty()) {
                    Log.d(
                        TAG,
                        "Syncing notification from ${sbn.packageName}"
                    )

                    // Save the app to our list if it's new (auto-enable new apps)
                    if (appSettings == null) {
                        Log.d(TAG, "New app detected: ${sbn.packageName}, adding to preferences")
                        saveNewAppToPreferences(sbn.packageName, appName)
                    }

                    ensureActive()
                    if (!isCurrentNotification(sbn)) return@launch
                    val notificationId = NotificationDismissalUtil.registerNotification(sbn)

                    // Titles are the protocol action identifiers. Do not expose ambiguous actions
                    // or manufacture a "Mark as read" action an Android app did not supply.
                    val nativeActions = notification.actions.orEmpty()
                    val descriptors = NotificationDismissalUtil.actionDescriptors(nativeActions)
                    val actions = NotificationActionPolicy.unambiguousIndices(descriptors).map { index ->
                        val descriptor = descriptors[index]
                        descriptor.name to if (descriptor.supportsReply) "reply" else "button"
                    }

                    // Check for progress bar extras
                    var progress: Int? = null
                    var progressMax: Int? = null
                    var progressIndeterminate: Boolean? = null
                    val ongoing = (notification.flags and Notification.FLAG_ONGOING_EVENT) != 0

                    try {
                        val hasProgress = extras.containsKey(Notification.EXTRA_PROGRESS) ||
                                extras.containsKey(Notification.EXTRA_PROGRESS_MAX)
                        if (hasProgress) {
                            val maxVal = extras.getInt(Notification.EXTRA_PROGRESS_MAX, 0)
                            val progressVal = extras.getInt(Notification.EXTRA_PROGRESS, 0)
                            val indeterminateVal = extras.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE, false)

                            if (maxVal > 0 || indeterminateVal) {
                                progress = progressVal
                                progressMax = maxVal
                                progressIndeterminate = indeterminateVal
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to parse notification progress: ${e.message}")
                    }

                    // Get notification priority (alerting vs silent)
                    var priority = getNotificationPriority(sbn)
                    if (progressMax != null || progressIndeterminate == true) {
                        priority = "silent"
                    }

                    // Create notification JSON with actions and progress details
                    val notificationJson = JsonUtil.toSingleLine(
                        JsonUtil.createNotificationJson(
                            id = notificationId,
                            title = title,
                            body = body,
                            app = appName,
                            packageName = sbn.packageName,
                            priority = priority,
                            actions = actions,
                            progress = progress,
                            progressMax = progressMax,
                            progressIndeterminate = progressIndeterminate,
                            ongoing = ongoing
                        )
                    )

                    ensureActive()
                    if (sentNotifications.matches(sbn.key, notificationJson)) return@launch
                    if (BackgroundWorkController.isPaused || !isCurrentNotification(sbn)) return@launch

                    Log.d(TAG, "Sending notification via WS/BLE")
                    val success = WebSocketUtil.sendMessage(notificationJson)
                    if (success) {
                        sentNotifications.remember(sbn.key, notificationJson)
                        Log.d(
                            TAG,
                            "Notification sent successfully"
                        )
                    } else {
                        Log.e(TAG, "Failed to send notification")
                    }
                } else {
                    Log.d(TAG, "Skipping empty notification from ${sbn.packageName}")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error processing notification: ${e.message}")
            }
            }
        }
    }

    private fun scheduleMediaRefresh() {
        if (BackgroundWorkController.isPaused || isMediaListenerPaused || !isNowPlayingEnabled) return
        if (mediaRefreshJob?.isActive == true) return
        mediaRefreshJob = workScope.launch {
            delay(100) // Collapse notification bursts; binder queries and artwork encoding stay off the main thread.
            if (BackgroundWorkController.isPaused || isMediaListenerPaused || !isNowPlayingEnabled) return@launch
            val previous = currentMediaInfo
            val refreshed = getMediaInfo(this@MediaNotificationListener)
            // Binder queries/bitmap encoding are synchronous and can finish after cancellation.
            ensureActive()
            if (BackgroundWorkController.isPaused || isMediaListenerPaused || !isNowPlayingEnabled) return@launch
            currentMediaInfo = refreshed
            if (hasSignificantMediaChange(previous, refreshed)) {
                SyncManager.onMediaStateChanged(this@MediaNotificationListener)
            }
        }
    }

    override fun onDestroy() {
        listenerConnected = false
        stopSessionObservers()
        serviceInstance = null
        serviceJob.cancel()
        currentMediaInfo = null
        sentNotifications.clear()
        MediaArtworkCache.clear()
        super.onDestroy()
    }

    private fun isCurrentNotification(sbn: StatusBarNotification): Boolean = try {
        getActiveNotifications(arrayOf(sbn.key))?.singleOrNull()?.let {
            it.key == sbn.key && it.postTime == sbn.postTime
        } == true
    } catch (_: Exception) { false }

    private fun getNotificationPriority(sbn: StatusBarNotification): String {
        return try {
            val ranking = Ranking()
            if (currentRanking.getRanking(sbn.key, ranking)) {
                val importance = ranking.importance
                if (importance >= NotificationManager.IMPORTANCE_DEFAULT) {
                    "alerting"
                } else {
                    "silent"
                }
            } else {
                "alerting" // Default to alerting if ranking not found
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error getting notification priority: ${e.message}")
            "alerting"
        }
    }

    private fun shouldSkipNotification(sbn: StatusBarNotification): Boolean {
        // Skip system packages
        return SYSTEM_PACKAGES.contains(sbn.packageName)
    }

    private fun getAppNameFromPackage(packageName: String): String {
        return try {
            val applicationInfo = packageManager.getApplicationInfo(packageName, 0)
            packageManager.getApplicationLabel(applicationInfo).toString()
        } catch (e: Exception) {
            packageName
        }
    }

    private suspend fun saveNewAppToPreferences(packageName: String, appName: String) {
        try {
            val isSystemApp = try {
                val applicationInfo = packageManager.getApplicationInfo(packageName, 0)
                (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
            } catch (e: Exception) {
                false
            }

            val newApp = app.androp.android.domain.model.NotificationApp(
                packageName = packageName,
                appName = appName,
                isEnabled = true,
                isSystemApp = isSystemApp,
                lastUpdated = System.currentTimeMillis()
            )

            dataStoreManager.updateNotificationApps { currentApps ->
                if (currentApps.any { it.packageName == packageName }) currentApps else currentApps + newApp
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error saving new app to preferences", e)
        }
    }
}
