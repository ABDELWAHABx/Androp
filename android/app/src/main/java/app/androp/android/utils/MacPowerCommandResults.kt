package app.androp.android.utils

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

data class MacPowerCommandResponse(
    val requestId: String,
    val action: String,
    val accepted: Boolean,
    val error: String? = null
)

/** Responses describe command acceptance, not proof that the Mac physically slept. */
object MacPowerCommandResults {
    private val _latest = MutableStateFlow<MacPowerCommandResponse?>(null)
    val latest = _latest.asStateFlow()

    fun handle(data: JSONObject) {
        if (BackgroundWorkController.isPaused) return
        val id = data.optString("requestId")
        val action = data.optString("action")
        if (id.isEmpty() || id.length > 128 || action !in setOf("setKeepAwake", "sleep") ||
            data.opt("accepted") !is Boolean) return
        _latest.value = MacPowerCommandResponse(id, action, data.getBoolean("accepted"),
            data.optString("error").takeIf { it.isNotBlank() }?.take(256))
    }
}
