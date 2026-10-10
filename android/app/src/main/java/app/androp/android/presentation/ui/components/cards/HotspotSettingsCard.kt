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
            Toast.makeText(context, "Open Samsung Settings → Connections → Mobile Hotspot and Tethering.", Toast.LENGTH_LONG).show()
        }
    }
    RoundedCardContainer {
        Column(Modifier.padding(16.dp)) {
            Text("Hotspot from your Mac", style = MaterialTheme.typography.titleMedium)
            Text(
                if (Build.VERSION.SDK_INT >= 36)
                    "Allow Modify system settings once, then try Hotspot in androp on your Mac. Some Samsung firmware and carriers block control by ordinary apps even after permission is granted."
                else "This Android version does not expose the public hotspot control API. Use the phone's hotspot settings.",
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(vertical = 8.dp)
            )
            if (Build.VERSION.SDK_INT >= 36) {
                Button(onClick = { open(Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, Uri.parse("package:${context.packageName}"))) }) {
                    Text("Allow Modify system settings")
                }
            }
            Text("Data Saver must be off to start a Samsung hotspot. Android does not offer a normal permission to switch it off automatically. Use the button below, then retry from your Mac. Hotspot uses your mobile data and carrier plan.",
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(vertical = 8.dp))
            Button(onClick = { open(Intent("android.settings.TETHER_SETTINGS")) }) { Text("Open hotspot settings") }
            Button(onClick = { open(Intent("android.settings.DATA_SAVER_SETTINGS")) }) { Text("Open Data Saver settings") }
        }
    }
}
