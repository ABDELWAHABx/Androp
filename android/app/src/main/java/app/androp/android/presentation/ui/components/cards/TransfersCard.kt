package app.androp.android.presentation.ui.components.cards

import android.app.DownloadManager
import android.content.Intent
import android.text.format.DateUtils
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.FileDownload
import androidx.compose.material.icons.filled.FileUpload
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import app.androp.android.service.NotificationActionReceiver
import app.androp.android.utils.DashboardRecentTransfer
import app.androp.android.utils.DashboardTransfer
import app.androp.android.utils.SyncDashboardController

/**
 * Files moving between phone and Mac, from the same state the notification uses,
 * so the app and the shade always agree.
 */
@Composable
fun TransfersCard(canSend: Boolean, onSendFiles: () -> Unit, modifier: Modifier = Modifier) {
    val dashboard by SyncDashboardController.dashboardState.collectAsState()
    val active = if (dashboard.paused) emptyList() else dashboard.transfers
    val recent = dashboard.recent.take(4)
    val context = LocalContext.current

    Card(
        modifier = modifier.fillMaxWidth().animateContentSize(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Files", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                if (recent.isNotEmpty()) {
                    TextButton(onClick = {
                        runCatching { context.startActivity(Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                    }) { Text("Downloads") }
                }
            }
            active.forEach { ActiveTransferRow(it) }
            recent.forEach { RecentTransferRow(it) }
            if (active.isEmpty() && recent.isEmpty()) {
                Text(
                    "Share anything to androp, or drop files on androp on your Mac.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            FilledTonalButton(onClick = onSendFiles, enabled = canSend, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Default.FileUpload, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Send files to Mac")
            }
        }
    }
}

@Composable
private fun ActiveTransferRow(transfer: DashboardTransfer) {
    val context = LocalContext.current
    val progress by animateFloatAsState(transfer.percent / 100f, label = "transfer")
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                if (transfer.sending) Icons.Default.FileUpload else Icons.Default.FileDownload,
                contentDescription = if (transfer.sending) "Sending" else "Receiving",
                tint = MaterialTheme.colorScheme.primary
            )
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(transfer.name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyLarge)
                Text("${transfer.percent}%", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            IconButton(onClick = {
                context.sendBroadcast(Intent(context, NotificationActionReceiver::class.java).apply {
                    action = NotificationActionReceiver.ACTION_CANCEL_TRANSFER
                    putExtra("transfer_id", transfer.id)
                    putExtra("is_sending", transfer.sending)
                    putExtra("transfer_kind", transfer.kind)
                })
            }) { Icon(Icons.Default.Close, contentDescription = "Cancel") }
        }
        LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth())
    }
}

@Composable
private fun RecentTransferRow(item: DashboardRecentTransfer) {
    val context = LocalContext.current
    val open = item.uri?.let { uri ->
        {
            val parsed = uri.toUri()
            val type = runCatching { context.contentResolver.getType(parsed) }.getOrNull() ?: "*/*"
            runCatching {
                context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(parsed, type)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            Unit
        }
    }
    Row(
        modifier = Modifier.fillMaxWidth().then(if (open != null) Modifier.clickable(onClick = open) else Modifier),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            when {
                !item.success -> Icons.Default.ErrorOutline
                else -> Icons.AutoMirrored.Filled.InsertDriveFile
            },
            contentDescription = null,
            tint = if (item.success) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.error
        )
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(item.name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyLarge)
            Text(
                listOf(
                    when {
                        !item.success -> "Failed"
                        item.sending -> "Sent to Mac"
                        else -> "From Mac"
                    },
                    DateUtils.getRelativeTimeSpanString(item.finishedAt, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()
                ).joinToString(" · "),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
