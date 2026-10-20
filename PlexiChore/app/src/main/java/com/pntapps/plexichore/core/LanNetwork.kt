package com.pntapps.plexichore.core

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.util.Log
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.Socket

/**
 * Keeps LAN traffic on the local network when a VPN is active (always-on VPN, Samsung Secure Wi-Fi,
 * corporate profiles): otherwise broadcasts go into tun0 and a TCP connect to 192.168.x.y is
 * tunnelled away unless the VPN happens to allow LAN bypass. Without a VPN nothing is changed.
 */
internal object LanNetwork {
    private const val TAG = "PlexiLan"
    @Volatile private var cm: ConnectivityManager? = null

    fun init(context: Context) {
        if (cm == null) cm = context.applicationContext.getSystemService(ConnectivityManager::class.java)
    }

    /** The Wi-Fi/Ethernet network to bind to, only when the default network is a VPN. */
    private fun lanNetworkIfVpn(): Network? {
        val c = cm ?: return null
        return runCatching {
            val active = c.activeNetwork ?: return null
            val activeCaps = c.getNetworkCapabilities(active) ?: return null
            if (!activeCaps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return null
            @Suppress("DEPRECATION")
            c.allNetworks.firstOrNull { n ->
                val caps = c.getNetworkCapabilities(n) ?: return@firstOrNull false
                !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                    (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))
            }
        }.getOrNull()
    }

    fun bindIfVpn(socket: DatagramSocket) {
        val n = lanNetworkIfVpn() ?: return
        runCatching { n.bindSocket(socket) }
            .onSuccess { Log.i(TAG, "VPN active: discovery socket bound to the local network") }
            .onFailure { Log.w(TAG, "Cannot bind discovery socket to the LAN: ${it.message}") }
    }

    /** Binds [socket] to the LAN when a VPN is active and [address] is a private/link-local IPv4 address. */
    fun bindIfVpn(socket: Socket, address: String) {
        val ip = runCatching { InetAddress.getByName(address) }.getOrNull() as? Inet4Address ?: return
        if (ip.isLoopbackAddress || !(ip.isSiteLocalAddress || ip.isLinkLocalAddress)) return
        val n = lanNetworkIfVpn() ?: return
        runCatching { n.bindSocket(socket) }
            .onSuccess { Log.i(TAG, "VPN active: connection to $address bound to the local network") }
            .onFailure { Log.w(TAG, "Cannot bind socket to the LAN: ${it.message}") }
    }
}
