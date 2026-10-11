package app.androp.android.presentation.ui.components.cards

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import app.androp.android.utils.PermissionUtil

/**
 * Only what still needs doing: pairing, then one "Finish setup" button. It asks for every
 * runtime permission in a single system sheet, then opens each special-access screen in turn.
 * The card disappears once everything is granted.
 */
@Composable
fun DashboardActionsCard(
    paused: Boolean,
    hasPairedDevice: Boolean,
    onPair: () -> Unit,
    onRequestPermissions: (Array<String>) -> Unit
) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    // Re-check whenever the user comes back from a settings screen.
    var resumes by remember { mutableIntStateOf(0) }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) resumes++ }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    val runtime = remember(resumes) { PermissionUtil.missingRuntimePermissions(context) }
    val steps = remember(resumes) { PermissionUtil.missingSetupSteps(context) }

    val needsPairing = !hasPairedDevice && !paused
    val needsSetup = hasPairedDevice && (runtime.isNotEmpty() || steps.isNotEmpty())
    if (!needsPairing && !needsSetup) return

    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceBright)
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (needsPairing) {
                Text("Pair your Mac", style = MaterialTheme.typography.titleMedium)
                Text("Open androp on your Mac and scan the code.", style = MaterialTheme.typography.bodyMedium)
                FilledTonalButton(onClick = onPair, modifier = Modifier.fillMaxWidth()) { Text("Scan code") }
            } else {
                Text("Finish setup", style = MaterialTheme.typography.titleMedium)
                Text(
                    if (runtime.isNotEmpty()) "Allow androp to reach your Mac, calls and notifications."
                    else steps.first().label,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                FilledTonalButton(
                    onClick = {
                        if (runtime.isNotEmpty()) onRequestPermissions(runtime) else steps.first().open(context)
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    val remaining = (if (runtime.isNotEmpty()) 1 else 0) + steps.size
                    Text(if (remaining > 1) "Continue · $remaining left" else "Continue")
                }
            }
        }
    }
}
