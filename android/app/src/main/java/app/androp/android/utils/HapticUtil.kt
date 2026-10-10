package app.androp.android.utils

import androidx.compose.ui.hapticfeedback.HapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.lifecycle.Lifecycle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

object HapticUtil {
    private val loadingJobs = java.util.concurrent.CopyOnWriteArraySet<Job>()

    fun stopLoadingHaptics() {
        loadingJobs.forEach { it.cancel() }
        loadingJobs.clear()
    }

    /**
     * Perform a light tick haptic - for subtle interactions like swiping
     */
    fun performLightTick(haptics: HapticFeedback?) {
        try {
            haptics?.performHapticFeedback(HapticFeedbackType.TextHandleMove)
        } catch (_: Exception) {
        }
    }

    /**
     * Perform a medium tick haptic - for toggles and buttons
     */
    fun performClick(haptics: HapticFeedback?) {
        try {
            haptics?.performHapticFeedback(HapticFeedbackType.LongPress)
        } catch (_: Exception) {
        }
    }

    /**
     * Perform a toggle ON haptic - slightly stronger
     */
    fun performToggleOn(haptics: HapticFeedback?) {
        try {
            haptics?.performHapticFeedback(HapticFeedbackType.LongPress)
        } catch (_: Exception) {
        }
    }

    /**
     * Perform a toggle OFF haptic - slightly lighter
     */
    fun performToggleOff(haptics: HapticFeedback?) {
        try {
            haptics?.performHapticFeedback(HapticFeedbackType.TextHandleMove)
        } catch (_: Exception) {
        }
    }

    /**
     * Perform a success haptic - 3 quick taps for successful operations
     */
    fun performSuccess(haptics: HapticFeedback?) {
        try {
            CoroutineScope(Dispatchers.Main).launch {
                haptics?.performHapticFeedback(HapticFeedbackType.LongPress)
                delay(100)
                haptics?.performHapticFeedback(HapticFeedbackType.LongPress)
                delay(50)
                haptics?.performHapticFeedback(HapticFeedbackType.LongPress)
            }
        } catch (_: Exception) {
        }
    }

    /**
     * Start repeating haptic ticks for loading states
     * Returns a Job that can be cancelled to stop the haptics
     *
     * If a lifecycle is provided, haptics will only fire while the lifecycle
     * is at least STARTED (i.e. the app/screen is in foreground). This prevents
     * haptics from triggering while the app is backgrounded.
     */
    fun startLoadingHaptics(haptics: HapticFeedback?, lifecycle: Lifecycle? = null): Job {
        val job = CoroutineScope(Dispatchers.Main).launch {
            while (isActive && !BackgroundWorkController.isPaused) {
                // Loading feedback has no purpose while the app is hidden.
                if (lifecycle?.currentState?.isAtLeast(Lifecycle.State.STARTED) == false) break
                performLightTick(haptics)
                delay(750)
            }
        }
        loadingJobs.add(job)
        job.invokeOnCompletion { loadingJobs.remove(job) }
        return job
    }
}
