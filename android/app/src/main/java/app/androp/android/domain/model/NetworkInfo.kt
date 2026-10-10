package app.androp.android.domain.model

data class NetworkInfo(
    val isConnected: Boolean,
    val isWifi: Boolean,
    val ipAddress: String?
)