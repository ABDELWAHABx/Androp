package app.androp.android.presentation.ui.components.cards

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.androp.android.presentation.ui.components.RoundedCardContainer
import app.androp.android.utils.HotspotControlManager

/** Setup is always a user gesture; incoming remote commands never launch phone activities. */
@Composable
fun HotspotSettingsCard(context: Context) {
    fun open(intent: Intent) {
        try {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: RuntimeException) {
            Toast.makeText(context, "Open Settings → Hotspot", Toast.LENGTH_SHORT).show()
        }
    }
    // One switch-like row: grant once, then Connect on the Mac does the rest.
    val canControl = Build.VERSION.SDK_INT >= 36
    val granted = canControl && runCatching { Settings.System.canWrite(context) }.getOrDefault(false)
    RoundedCardContainer {
        Column(Modifier.padding(16.dp)) {
            Text("Hotspot", style = MaterialTheme.typography.titleMedium)
            Text(
                when {
                    granted -> "Your Mac can turn it on."
                    canControl -> "Let your Mac turn on Hotspot when it needs internet."
                    else -> "Your Mac will ask you to turn it on."
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(vertical = 8.dp)
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (canControl && !granted) {
                    Button(onClick = { open(Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, Uri.parse("package:${context.packageName}"))) }) {
                        Text("Allow")
                    }
                } else {
                    Button(onClick = { connectMacToHotspot(context) }) { Text("Connect Mac") }
                }
                TextButton(onClick = { open(Intent("android.settings.TETHER_SETTINGS")) }) { Text("Hotspot settings") }
            }
        }
    }
}

/** Home-screen shortcut while the Mac is connected: one tap and the Mac joins this phone's Hotspot. */
@Composable
fun HotspotConnectMacCard(context: Context) {
    RoundedCardContainer {
        Row(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Column(Modifier.weight(1f)) {
                Text("Hotspot", style = MaterialTheme.typography.titleMedium)
                Text(
                    "Get your Mac online through this phone.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Button(onClick = { connectMacToHotspot(context) }) { Text("Connect Mac") }
        }
    }
}

/**
 * Asks the Mac to run its Connect: it turns Hotspot on through this app when Android allows it,
 * then joins with the password saved on the Mac. Where Android doesn't allow it, opens the
 * Hotspot page so the switch is one tap away; the Mac keeps looking and joins once it's on.
 */
fun connectMacToHotspot(context: Context) {
    if (!HotspotControlManager.askMacToConnect()) {
        Toast.makeText(context, "Connect to your Mac first.", Toast.LENGTH_SHORT).show()
        return
    }
    val automatic = Build.VERSION.SDK_INT >= 36 &&
        runCatching { Settings.System.canWrite(context) }.getOrDefault(false)
    if (automatic) {
        Toast.makeText(context, "Your Mac is turning on Hotspot and joining it.", Toast.LENGTH_SHORT).show()
        return
    }
    Toast.makeText(context, "Turn on Hotspot. Your Mac joins as soon as it appears.", Toast.LENGTH_LONG).show()
    try {
        context.startActivity(Intent("android.settings.TETHER_SETTINGS").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (_: RuntimeException) {
        Toast.makeText(context, "Open Settings → Hotspot", Toast.LENGTH_SHORT).show()
    }
}
