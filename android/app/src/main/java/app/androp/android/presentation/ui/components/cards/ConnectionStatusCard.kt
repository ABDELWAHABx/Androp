package app.androp.android.presentation.ui.components.cards

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.androp.android.R
import app.androp.android.domain.model.ConnectedDevice
import app.androp.android.domain.model.UiState

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ConnectionStatusCard(
    isConnected: Boolean,
    isConnecting: Boolean,
    onDisconnect: () -> Unit,
    connectedDevice: ConnectedDevice? = null,
    lastConnected: Boolean,
    uiState: UiState,
    isPaused: Boolean = false,
    onTogglePause: (() -> Unit)? = null,
    connectionLabel: String = "Connected",
    modifier: Modifier = Modifier
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceBright)
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                if (isConnecting && !isPaused) LoadingIndicator(modifier = Modifier.size(40.dp))
                else Icon(
                    painter = painterResource(if (isPaused) R.drawable.rounded_pause_24
                        else if (isConnected) R.drawable.rounded_devices_24 else R.drawable.rounded_devices_off_24),
                    contentDescription = null,
                    modifier = Modifier.size(32.dp),
                    tint = MaterialTheme.colorScheme.primary
                )
                Column(Modifier.weight(1f)) {
                    Text(connectedDevice?.name?.takeIf { isConnected } ?: "androp",
                        style = MaterialTheme.typography.titleLarge)
                    Text(when {
                        isPaused -> "Paused · Background sync stopped"
                        isConnecting -> "Connecting to your Mac…"
                        isConnected -> connectionLabel
                        else -> "Ready to connect"
                    }, style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                onTogglePause?.let { toggle ->
                    Button(onClick = toggle, modifier = Modifier.weight(1f).height(48.dp)) {
                        Icon(painterResource(if (isPaused) R.drawable.rounded_play_arrow_24 else R.drawable.rounded_pause_24),
                            contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(6.dp))
                        Text(if (isPaused) "Resume" else "Pause")
                    }
                }
                if (isConnected && !isPaused) {
                    OutlinedButton(onClick = onDisconnect, modifier = Modifier.weight(1f).height(48.dp)) {
                        Text("Disconnect")
                    }
                }
            }
        }
    }
}
