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
    // Only what still needs doing. Remote, Clipboard and Settings already have tabs,
    // so this card disappears entirely once the phone is paired and permitted.
    val needsPairing = !hasPairedDevice && !paused
    if (!needsPairing && notificationsAllowed && !notificationSyncNeedsAccess && !nearbyNeedsAccess) return
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceBright)
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (needsPairing) {
                Text("Pair your Mac", style = MaterialTheme.typography.titleMedium)
                Text("Open androp on your Mac and scan the code.",
                    style = MaterialTheme.typography.bodyMedium)
                FilledTonalButton(onClick = onPair, modifier = Modifier.fillMaxWidth()) {
                    Text("Scan code")
                }
            }
            if (!notificationsAllowed) {
                TextButton(onClick = onEnableDashboard) { Text("Allow notifications") }
            }
            if (notificationSyncNeedsAccess) {
                TextButton(onClick = onEnableNotificationSync) { Text("Show phone notifications on Mac") }
            }
            if (nearbyNeedsAccess) {
                TextButton(onClick = onNearbyPermission) { Text("Allow Nearby devices") }
            }
        }
    }
}
