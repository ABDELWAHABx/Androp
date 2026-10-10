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
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.androp.android.quickshare.QuickShareService
import app.androp.android.utils.SyncDashboardController

/** Consent is always reachable in the app, including when notifications are denied. */
@Composable
fun IncomingNearbyConsentCard() {
    val dashboard by SyncDashboardController.dashboardState.collectAsState()
    if (dashboard.paused || dashboard.consents.isEmpty()) return

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        dashboard.consents.forEach { consent ->
            key(consent.id) {
                var responding by remember { mutableStateOf(false) }
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.secondaryContainer)
                ) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Incoming Nearby files", style = MaterialTheme.typography.titleMedium)
                        Text(
                            "From ${consent.sender.take(80)}",
                            style = MaterialTheme.typography.bodyLarge,
                            maxLines = 2, overflow = TextOverflow.Ellipsis
                        )
                        Text(consent.files.take(240), maxLines = 3, overflow = TextOverflow.Ellipsis)
                        Text("Accept only if you expect this transfer.",
                            style = MaterialTheme.typography.bodySmall)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(
                                onClick = {
                                    responding = true
                                    QuickShareService.respondToShare(consent.id, true)
                                },
                                enabled = !responding,
                                modifier = Modifier.weight(1f).heightIn(min = 48.dp)
                            ) { Text("Accept") }
                            OutlinedButton(
                                onClick = {
                                    responding = true
                                    QuickShareService.respondToShare(consent.id, false)
                                },
                                enabled = !responding,
                                modifier = Modifier.weight(1f).heightIn(min = 48.dp)
                            ) { Text("Reject") }
                        }
                    }
                }
            }
        }
    }
}
