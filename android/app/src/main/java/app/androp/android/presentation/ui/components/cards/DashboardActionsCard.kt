package app.androp.android.presentation.ui.components.cards

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
fun DashboardActionsCard(
    connected: Boolean,
    paused: Boolean,
    hasPairedDevice: Boolean,
    notificationsAllowed: Boolean,
    notificationSyncNeedsAccess: Boolean,
    nearbyNeedsAccess: Boolean,
    onRemote: () -> Unit,
    onFiles: () -> Unit,
    onClipboard: () -> Unit,
    onSettings: () -> Unit,
    onPair: () -> Unit,
    onEnableDashboard: () -> Unit,
    onEnableNotificationSync: () -> Unit,
    onNearbyPermission: () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceBright)
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Quick actions", style = MaterialTheme.typography.titleMedium)
            if (!connected && !paused) {
                Text("Open androp on your Mac and scan its QR code. Keep both devices on the same Wi-Fi.",
                    style = MaterialTheme.typography.bodyMedium)
                FilledTonalButton(onClick = onPair, modifier = Modifier.fillMaxWidth()) {
                    Text("Pair your Mac")
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilledTonalButton(onClick = onRemote, enabled = connected && !paused,
                    modifier = Modifier.weight(1f)) { Text("Remote Mac") }
                FilledTonalButton(onClick = onFiles, enabled = hasPairedDevice && !paused,
                    modifier = Modifier.weight(1f)) { Text("Files") }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilledTonalButton(onClick = onClipboard, enabled = connected && !paused,
                    modifier = Modifier.weight(1f)) { Text("Clipboard") }
                FilledTonalButton(onClick = onSettings, modifier = Modifier.weight(1f)) {
                    Text("Settings")
                }
            }
            if (!notificationsAllowed) {
                TextButton(onClick = onEnableDashboard) { Text("Enable notification dashboard") }
            }
            if (notificationSyncNeedsAccess) {
                TextButton(onClick = onEnableNotificationSync) { Text("Enable phone notification sync") }
            }
            if (nearbyNeedsAccess) {
                TextButton(onClick = onNearbyPermission) { Text("Allow Nearby devices for Bluetooth") }
            }
        }
    }
}
