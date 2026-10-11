package app.androp.android.presentation.ui.components.cards

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.androp.android.presentation.ui.components.RoundedCardContainer

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
            if (canControl && !granted) {
                Button(onClick = { open(Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, Uri.parse("package:${context.packageName}"))) }) {
                    Text("Allow")
                }
            } else {
                TextButton(onClick = { open(Intent("android.settings.TETHER_SETTINGS")) }) { Text("Hotspot settings") }
            }
        }
    }
}
