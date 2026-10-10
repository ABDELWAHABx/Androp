package app.androp.android.utils

import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** A short, user-requested alert. There is no background work while inactive. */
object FindPhoneManager {
    private const val TAG = "FindPhoneManager"
    private const val MAX_DURATION_MS = 30_000L
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val lock = Any()
    private val _isRinging = MutableStateFlow(false)
    val isRinging: StateFlow<Boolean> = _isRinging.asStateFlow()
    private var generation = 0L
    private var timeoutJob: Job? = null
    private var preparationJob: Job? = null
    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null

    fun start(context: Context): Boolean = synchronized(lock) {
        if (BackgroundWorkController.isPaused) return false
        if (_isRinging.value) return true // Repeated commands cannot prolong an active alert.
        val applicationContext = context.applicationContext
        val audio = applicationContext.getSystemService(AudioManager::class.java)
        val notifications = applicationContext.getSystemService(NotificationManager::class.java)
        // Keep a visible, stoppable alert even when sound/vibration is suppressed.
        // Do not bypass silent mode, Do Not Disturb, or the user's ringtone volume.
        val mayInterrupt = audio?.ringerMode != AudioManager.RINGER_MODE_SILENT &&
            notifications?.currentInterruptionFilter == NotificationManager.INTERRUPTION_FILTER_ALL
        val deviceVibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            applicationContext.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            applicationContext.getSystemService(Vibrator::class.java)
        }
        val mayVibrate = mayInterrupt && deviceVibrator?.hasVibrator() == true
        val mayPlay = mayInterrupt && audio?.ringerMode == AudioManager.RINGER_MODE_NORMAL &&
            audio.getStreamVolume(AudioManager.STREAM_RING) > 0
        val token = ++generation
        _isRinging.value = true
        timeoutJob = scope.launch {
            delay(MAX_DURATION_MS)
            stopIfCurrent(token)
        }
        preparationJob = scope.launch {
            try {
                val attributes = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
                synchronized(lock) {
                    if (!isCurrent(token)) return@launch
                    if (mayVibrate) {
                        vibrator = deviceVibrator
                        val effect = VibrationEffect.createWaveform(longArrayOf(0, 300, 200, 300, 1_200), 0)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            deviceVibrator.vibrate(effect, VibrationAttributes.Builder()
                                .setUsage(VibrationAttributes.USAGE_RINGTONE).build())
                        } else {
                            @Suppress("DEPRECATION")
                            deviceVibrator.vibrate(effect, attributes)
                        }
                    }
                }
                if (!mayPlay) return@launch
                // Opening a content URI and preparing audio must not block the UI.
                withContext(Dispatchers.IO) {
                    val candidate = MediaPlayer()
                    var adopted = false
                    try {
                        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                            ?: return@withContext
                        candidate.setAudioAttributes(attributes)
                        candidate.setDataSource(applicationContext, uri)
                        candidate.isLooping = true
                        candidate.setVolume(0.45f, 0.45f)
                        candidate.prepare()
                        withContext(Dispatchers.Main.immediate) {
                            synchronized(lock) {
                                if (isCurrent(token)) {
                                    candidate.setOnErrorListener { _, _, _ -> releaseAudioIfCurrent(token); true }
                                    player = candidate
                                    adopted = true
                                    candidate.start()
                                }
                            }
                        }
                    } finally {
                        if (!adopted) candidate.release()
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Unable to play phone alert: ${e.javaClass.simpleName}")
                // Audio failure still leaves the dashboard's visible alert active
                // until Stop or the same 30-second deadline.
                releaseAudioIfCurrent(token)
            }
        }
        true
    }

    private fun isCurrent(token: Long) = generation == token && _isRinging.value && !BackgroundWorkController.isPaused

    private fun releaseAudioIfCurrent(token: Long) = synchronized(lock) {
        if (generation == token) {
            val activePlayer = player
            player = null
            try { activePlayer?.release() } catch (e: Exception) { Log.w(TAG, "Alert audio cleanup failed", e) }
        }
    }

    private fun stopIfCurrent(token: Long) = synchronized(lock) {
        if (generation == token) stop()
    }

    fun stop() = synchronized(lock) {
        generation++
        timeoutJob?.cancel()
        timeoutJob = null
        preparationJob?.cancel()
        preparationJob = null
        val activePlayer = player
        player = null
        try { activePlayer?.release() } catch (e: Exception) { Log.w(TAG, "Alert audio cleanup failed", e) }
        val activeVibrator = vibrator
        vibrator = null
        try { activeVibrator?.cancel() } catch (e: Exception) { Log.w(TAG, "Alert vibration cleanup failed", e) }
        _isRinging.value = false
        // Stream volume and audio focus are never changed, so nothing else needs restoring.
    }
}
