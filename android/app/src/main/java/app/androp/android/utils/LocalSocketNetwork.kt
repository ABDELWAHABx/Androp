package app.androp.android.utils

import android.content.Context
import android.net.ConnectivityManager
import android.net.InetAddresses
import android.net.Network
import android.net.NetworkCapabilities

internal object LocalSocketNetwork {
    /** Per-socket selection fixes local Wi-Fi while Android chooses cellular for internet.
     * Never bind the process, use a default route, or circumvent an active VPN. */
    fun forAddress(context: Context, host: String): Network? = runCatching {
        val target = InetAddresses.parseNumericAddress(host).address
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return null
        val networks = manager.allNetworks.toList()
        val capabilities = networks.map { manager.getNetworkCapabilities(it) }
        val vpnPresent = capabilities.any { it?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true }
        val candidates = networks.flatMapIndexed { index, network ->
            val caps = capabilities[index]
            if (caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) != true &&
                caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) != true) emptyList()
            else manager.getLinkProperties(network)?.linkAddresses.orEmpty().map {
                LocalSocketRouting.Candidate(index, it.prefixLength, it.address.address)
            }
        }
        LocalSocketRouting.select(target, candidates, vpnPresent)?.let { networks[it] }
    }.getOrNull()

    fun hasLocalNetwork(context: Context): Boolean = runCatching {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return false
        manager.allNetworks.any { network ->
            val caps = manager.getNetworkCapabilities(network)
            caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true ||
                caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true ||
                caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        }
    }.getOrDefault(false)
}
