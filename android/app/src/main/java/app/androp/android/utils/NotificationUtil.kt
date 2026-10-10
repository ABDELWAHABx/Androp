package app.androp.android.utils

import android.content.Context
import android.net.Uri

/** Routine sync, link and transfer events share the dashboard instead of spawning notifications. */
object NotificationUtil {
    private data class TransferReference(val id: String, val kind: String)
    private val transferIds = java.util.concurrent.ConcurrentHashMap<Pair<Int, Boolean>, TransferReference>()

    fun createFileChannel(context: Context) { SyncDashboardController.initialize(context) }

    fun showFileProgress(context: Context, notifId: Int, fileName: String, percent: Int,
        transferId: String, isSending: Boolean = false, etaString: String? = null, transferKind: String = "quickshare") {
        SyncDashboardController.initialize(context)
        transferIds[notifId to isSending] = TransferReference(transferId, transferKind)
        SyncDashboardController.progress(transferId, fileName, percent, isSending, transferKind)
    }

    fun showFileComplete(context: Context, notifId: Int, fileName: String, success: Boolean,
        isSending: Boolean = false, contentUri: Uri? = null, detail: String? = null) {
        SyncDashboardController.initialize(context)
        val id = transferIds.remove(notifId to isSending)?.id ?: notifId.toString()
        SyncDashboardController.complete(id, fileName, success, isSending, contentUri?.toString(), detail)
    }

    fun clearTransferKind(kind: String, sending: Boolean? = null) {
        transferIds.entries.removeIf { it.value.kind == kind && (sending == null || it.key.second == sending) }
    }

    fun showContinueBrowsingLink(context: Context, url: String, keepPrevious: Boolean = true) {
        SyncDashboardController.initialize(context)
        // Keep only the latest link; the clipboard history remains available inside the app.
        SyncDashboardController.link(url)
    }

    fun clearContinueBrowsingNotifications(context: Context) { SyncDashboardController.clearLink() }
}
