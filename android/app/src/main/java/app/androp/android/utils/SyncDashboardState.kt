package app.androp.android.utils

/** A small immutable projection; playback positions and byte counters never enter this model. */
data class DashboardTransfer(
    val id: String,
    val name: String,
    val percent: Int,
    val sending: Boolean,
    val kind: String = "quickshare"
)

data class DashboardConsent(val id: String, val sender: String, val files: String)

/** A finished transfer kept for the in-app list; [uri] is set for received files. */
data class DashboardRecentTransfer(
    val id: String,
    val name: String,
    val sending: Boolean,
    val success: Boolean,
    val uri: String?,
    val finishedAt: Long
)

data class SyncDashboardState(
    val owners: Set<String> = emptySet(),
    val ownerStatuses: Map<String, String> = emptyMap(),
    val paused: Boolean = false,
    val device: String? = null,
    val transport: String? = null,
    val connecting: Boolean = false,
    val reconnecting: Boolean = false,
    val battery: Int? = null,
    val charging: Boolean = false,
    val transfers: List<DashboardTransfer> = emptyList(),
    val consents: List<DashboardConsent> = emptyList(),
    val lastEvent: String? = null,
    val link: String? = null,
    val receivedFile: String? = null,
    val phoneAlert: Boolean = false,
    val hotspotSetup: String? = null,
    val cancelledTransfers: Set<String> = emptySet(),
    val recent: List<DashboardRecentTransfer> = emptyList()
) {
    val shouldRequestPromotion: Boolean
        get() = !paused && (transport != null || transfers.isNotEmpty() || phoneAlert)

    val shouldShow: Boolean
        get() = owners.isNotEmpty() || paused || phoneAlert || hotspotSetup != null || lastEvent != null || link != null || consents.isNotEmpty()

    val connectionLine: String
        get() = when {
            paused -> "Paused"
            transport != null -> listOfNotNull(device ?: "Mac", transport,
                battery?.let { "$it%${if (charging) " · Charging" else ""}" }).joinToString(" · ")
            connecting -> "Connecting to ${device ?: "Mac"}…"
            else -> "${device ?: "Mac"} · Not connected"
        }

    /** Notification title: the one thing happening now, the way system notifications read. */
    val headline: String
        get() = when {
            paused -> "Sync paused"
            phoneAlert -> "Ringing your phone"
            consents.isNotEmpty() -> "${consents.first().sender} wants to share"
            transfers.isNotEmpty() -> transfers.first().let { "${if (it.sending) "Sending" else "Receiving"} ${it.name}" }
            hotspotSetup != null -> "Turn on Hotspot"
            lastEvent != null -> lastEvent
            else -> device ?: "Mac"
        }

    /** Notification body: one short supporting line. */
    val detail: String
        get() = when {
            paused -> device ?: "Mac"
            phoneAlert -> "From ${device ?: "your Mac"}"
            consents.isNotEmpty() -> consents.first().files
            transfers.isNotEmpty() -> "${transfers.first().percent}%" +
                (if (transfers.size > 1) " · ${transfers.size - 1} more" else "") +
                " · ${device ?: "Mac"}"
            hotspotSetup != null -> hotspotSetupMessage ?: ""
            transport != null -> listOfNotNull(if (lastEvent != null) device ?: "Mac" else "Connected",
                battery?.let { "Mac $it%${if (charging) " ⚡" else ""}" }).joinToString(" · ")
            connecting -> "Connecting…"
            else -> "Not connected"
        }

    val activityLine: String
        get() = when {
            paused -> "Sync paused"
            phoneAlert -> "Ringing your phone"
            consents.isNotEmpty() -> "${consents.first().sender} wants to share files"
            transfers.isNotEmpty() -> transfers.first().let {
                "${if (it.sending) "Sending" else "Receiving"} ${it.name} · ${it.percent}%" +
                    if (transfers.size > 1) " · +${transfers.size - 1} files" else ""
            }
            hotspotSetup != null -> hotspotSetupMessage ?: "Hotspot setup"
            lastEvent != null -> lastEvent
            ownerStatuses.containsKey("send") -> ownerStatuses.getValue("send")
            ownerStatuses.containsKey("receive") -> ownerStatuses.getValue("receive")
            else -> connectionLine
        }

    val hotspotSetupMessage: String?
        get() = when (hotspotSetup) {
            "dataSaver" -> "Data Saver is on"
            "permission" -> "Let androp turn it on next time"
            "hotspot" -> "Your Mac is waiting for it"
            else -> null
        }

    fun withProgress(id: String, name: String, percent: Int, sending: Boolean, kind: String = "quickshare"): SyncDashboardState {
        if (paused || "$sending:$id" in cancelledTransfers) return this
        // Ten meaningful steps per file; ETA and every-byte progress do not refresh the shade.
        val step = percent.coerceIn(0, 100) / 10 * 10
        val transfer = DashboardTransfer(id, name, step, sending, kind)
        val existing = transfers.firstOrNull { it.id == id && it.sending == sending }
        if (existing == transfer) return this
        // Updating progress must not rotate the first row (and its Cancel action) to another file.
        val updated = if (existing != null) transfers.map {
            if (it.id == id && it.sending == sending) transfer else it
        } else (transfers + transfer).takeLast(8)
        return copy(transfers = updated,
            lastEvent = null, receivedFile = null)
    }

    fun finished(id: String, name: String, success: Boolean, sending: Boolean, uri: String?, now: Long): SyncDashboardState =
        copy(recent = (listOf(DashboardRecentTransfer(id, name, sending, success, uri?.takeIf { success }, now)) +
            recent.filterNot { it.id == id && it.sending == sending }).take(10))

    fun cancelTransfer(id: String, sending: Boolean): SyncDashboardState = copy(
        transfers = transfers.filterNot { it.id == id && it.sending == sending },
        cancelledTransfers = (cancelledTransfers + "$sending:$id").toList().takeLast(64).toSet(),
        lastEvent = "Transfer cancelled"
    )

    fun release(owner: String): SyncDashboardState = copy(
        owners = owners - owner,
        ownerStatuses = ownerStatuses - owner,
        transfers = when (owner) {
            "send" -> transfers.filterNot { it.sending }
            "receive" -> transfers.filter { it.sending || it.kind == "ws" }
            else -> transfers
        },
        consents = if (owner == "receive") emptyList() else consents
    )

    fun pause(): SyncDashboardState = copy(paused = true, transport = null, connecting = false,
        reconnecting = false, transfers = emptyList(), consents = emptyList(), lastEvent = null,
        link = null, receivedFile = null, phoneAlert = false, hotspotSetup = null)
}
