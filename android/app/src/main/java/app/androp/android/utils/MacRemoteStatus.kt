package app.androp.android.utils

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** What the Mac reports about accepting remote input; null until it says otherwise. */
object MacRemoteStatus {
    private val allowed = MutableStateFlow<Boolean?>(null)
    val inputAllowed: StateFlow<Boolean?> = allowed.asStateFlow()

    fun handle(data: org.json.JSONObject) {
        if (data.has("inputAllowed")) allowed.value = data.optBoolean("inputAllowed", true)
    }

    fun reset() { allowed.value = null }
}
