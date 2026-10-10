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
    val cancelledTransfers: Set<String> = emptySet()
) {
    val shouldRequestPromotion: Boolean
        get() = !paused && (transport != null || transfers.isNotEmpty() || phoneAlert)

    val shouldShow: Boolean
        get() = owners.isNotEmpty() || paused || phoneAlert || lastEvent != null || link != null || consents.isNotEmpty()

    val connectionLine: String
        get() = when {
            paused -> "Paused · Background syncing stopped"
            transport != null -> listOfNotNull(device ?: "Mac", transport,
                battery?.let { "$it%${if (charging) " · Charging" else ""}" }).joinToString(" · ")
            connecting -> "Connecting to ${device ?: "Mac"}"
            reconnecting -> "Waiting to reconnect${device?.let { " to $it" } ?: ""}"
            else -> "Ready${device?.let { " · $it" } ?: ""}"
        }

    val activityLine: String
        get() = when {
            paused -> "Resume when you're ready"
            phoneAlert -> "Find phone alert active"
            consents.isNotEmpty() -> "${consents.first().sender} wants to share files"
            transfers.isNotEmpty() -> transfers.first().let {
                "${if (it.sending) "Sending" else "Receiving"} ${it.name} · ${it.percent}%" +
                    if (transfers.size > 1) " · +${transfers.size - 1} files" else ""
            }
            lastEvent != null -> lastEvent
            ownerStatuses.containsKey("send") -> ownerStatuses.getValue("send")
            ownerStatuses.containsKey("receive") -> ownerStatuses.getValue("receive")
            else -> connectionLine
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
        link = null, receivedFile = null, phoneAlert = false)
}
