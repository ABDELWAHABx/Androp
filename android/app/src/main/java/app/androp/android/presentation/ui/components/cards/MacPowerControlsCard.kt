package app.androp.android.presentation.ui.components.cards

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import app.androp.android.utils.MacDeviceStatusManager
import app.androp.android.utils.MacPowerCommandResults
import app.androp.android.utils.MacPowerControlPolicy
import app.androp.android.utils.SyncDashboardController
import app.androp.android.utils.WebSocketUtil
import kotlinx.coroutines.delay
import org.json.JSONObject
import java.util.UUID

private data class PendingMacPowerCommand(
    val requestId: String,
    val action: String,
    val enabled: Boolean? = null
)

@Composable
fun MacPowerControlsCard() {
    val mac by MacDeviceStatusManager.macDeviceStatus.collectAsState()
    val dashboard by SyncDashboardController.dashboardState.collectAsState()
    val response by MacPowerCommandResults.latest.collectAsState()
    val powerError = mac?.powerError?.takeIf { it.isNotBlank() }
    val reportedEnabled = mac?.keepAwakeEnabled ?: return
    if (dashboard.paused || dashboard.transport == null) return
    val connected = WebSocketUtil.isConnected()

    var pending by remember { mutableStateOf<PendingMacPowerCommand?>(null) }
    var feedback by remember { mutableStateOf<String?>(null) }
    var sleepAccepted by remember { mutableStateOf(false) }

    fun request(action: String, enabled: Boolean? = null) {
        if (pending != null || !WebSocketUtil.isConnected()) return
        val requestId = UUID.randomUUID().toString()
        val data = JSONObject().put("action", action).put("requestId", requestId)
        if (enabled != null) data.put("enabled", enabled)
        val message = JSONObject().put("type", "macPowerControl").put("data", data)
        feedback = null
        if (WebSocketUtil.sendMessage(message.toString())) {
            pending = PendingMacPowerCommand(requestId, action, enabled)
        } else {
            feedback = "Couldn't reach your Mac. Reconnect and try again."
        }
    }

    LaunchedEffect(pending, response, reportedEnabled) {
        val command = pending ?: return@LaunchedEffect
        val result = response?.takeIf { it.requestId == command.requestId && it.action == command.action }
        when {
            result?.accepted == false -> {
                feedback = result.error?.takeIf { it.isNotBlank() }?.take(240)
                    ?: "Your Mac couldn't complete the request."
                pending = null
            }
            command.action == "sleep" && result?.accepted == true -> {
                feedback = "Mac accepted the sleep request."
                sleepAccepted = true
                pending = null
            }
            command.action == "setKeepAwake" && command.enabled != null &&
                MacPowerControlPolicy.toggleConfirmed(command.enabled, reportedEnabled) -> {
                // A reported Mac state confirms the toggle; enqueueing alone never does.
                feedback = null
                pending = null
            }
        }
    }

    LaunchedEffect(pending?.requestId) {
        val requestId = pending?.requestId ?: return@LaunchedEffect
        delay(10_000)
        if (pending?.requestId == requestId) {
            feedback = "No confirmation from your Mac. Check the connection and try again."
            pending = null
        }
    }

    LaunchedEffect(powerError) {
        if (powerError != null) {
            pending = null
            sleepAccepted = false
            feedback = null
        }
    }

    // Acceptance is a queued OS request, not proof of sleep. If the Mac stays
    // connected, allow a later retry rather than permanently disabling the action.
    LaunchedEffect(sleepAccepted) {
        if (sleepAccepted) {
            delay(10_000)
            sleepAccepted = false
        }
    }

    LaunchedEffect(connected, mac?.lidClosed) {
        if (!connected) pending = null
        if (!connected || mac?.lidClosed != true) sleepAccepted = false
    }

    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceBright)
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Keep Mac awake", style = MaterialTheme.typography.titleMedium)
                    Text("During file transfers, active remote control and media playback.",
                        style = MaterialTheme.typography.bodySmall)
                }
                Switch(
                    checked = reportedEnabled,
                    enabled = connected && pending == null && !sleepAccepted,
                    onCheckedChange = { request("setKeepAwake", it) },
                    modifier = Modifier.semantics { contentDescription = "Keep Mac awake" }
                )
            }
            val closedLidCaption = when {
                mac?.closedLidOverrideActive == true -> "Experimental closed-lid mode active"
                mac?.closedLidOverrideSupported == true && mac?.closedLidOverrideEnabled == true ->
                    if (reportedEnabled) "Closed-lid mode will start during activity"
                    else "Enable Keep Mac awake to use closed-lid mode during activity"
                else -> "Prevents idle sleep. Closing the lid still follows macOS sleep rules."
            }
            Text(closedLidCaption, style = MaterialTheme.typography.bodySmall)
            if (mac?.closedLidOverrideSupported == true && mac?.closedLidOverrideEnabled != true) {
                Text("Enable closed-lid testing in androp’s Mac settings.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            val status = when {
                !connected -> "Reconnect to change your Mac’s power settings."
                pending != null -> "Waiting for confirmation from your Mac…"
                mac?.keepAwakeActive == true -> mac?.keepAwakeReason?.takeIf { it.isNotBlank() }
                    ?.let { "Active · ${it.take(120)}" } ?: "Keep awake is active"
                reportedEnabled -> "Ready when an activity needs it"
                else -> "Off"
            }
            Text(status, style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (MacPowerControlPolicy.canSleep(mac?.lidClosed, connected, dashboard.paused)) {
                Text("Lid closed", style = MaterialTheme.typography.bodySmall)
                Button(
                    onClick = { request("sleep") },
                    enabled = pending == null && !sleepAccepted,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)
                ) { Text("Sleep Mac") }
            }
            if (powerError != null) {
                Text("Mac power request failed: ${powerError.take(240)}",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error)
            } else {
                feedback?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
            }
        }
    }
}
