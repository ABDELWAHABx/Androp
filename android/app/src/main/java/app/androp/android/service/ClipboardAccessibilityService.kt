package app.androp.android.service

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import app.androp.android.presentation.ui.activities.ClipboardActionActivity
import app.androp.android.utils.BackgroundWorkController
import app.androp.android.utils.WebSocketUtil

/**
 * Lets copies made in any app reach the Mac automatically.
 *
 * Android 10+ only lets the focused app (or the keyboard, or system apps such as Phone Link
 * on Samsung) read the clipboard. This service notices a Copy tap or a "Copied" toast and
 * opens an invisible window for a moment, which may then read the clipboard and forward it.
 * It receives no window content, only the clicked control's label.
 */
class ClipboardAccessibilityService : AccessibilityService() {
    private val main = Handler(Looper.getMainLooper())
    private var lastLaunch = 0L

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (event.packageName == packageName || BackgroundWorkController.isPaused || !WebSocketUtil.isConnected()) return
        val label = (event.text.joinToString(" ") + " " + (event.contentDescription ?: "")).lowercase()
        if (!COPY_WORDS.containsMatchIn(label)) return
        val now = SystemClock.elapsedRealtime()
        if (now - lastLaunch < 800) return
        lastLaunch = now
        // Let the source app finish writing the clip before reading it.
        main.postDelayed({
            runCatching {
                startActivity(Intent(this, ClipboardActionActivity::class.java)
                    .setAction(ClipboardActionActivity.ACTION_AUTO)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION or
                        Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS))
            }
        }, 250)
    }

    override fun onInterrupt() = Unit

    private companion object {
        // "Copy", "Copy link", "Copied to clipboard" and common translations.
        val COPY_WORDS = Regex(
            "\\b(copy|copied|copier|copié|kopieren|kopiert|copiar|copiado|copia|copiato|kopiëren|kopyala|копировать|скопировано)\\b|نسخ|复制|複製|コピー|복사"
        )
    }
}
