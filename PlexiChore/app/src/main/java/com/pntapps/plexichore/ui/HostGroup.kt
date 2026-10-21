package com.pntapps.plexichore.ui

import com.pntapps.plexichore.core.DiscoveredHost
import com.pntapps.plexichore.core.HostDiscovery
import com.pntapps.plexichore.core.Transport

/**
 * One computer as shown on Home. The core can report the same machine more than once: the same
 * id on several addresses (Wi-Fi + Ethernet), or over USB (id "usb", loopback) *and* Wi-Fi at the
 * same time. They are merged so the user sees one card with every available transport.
 *
 * [primary] is what "Connect" uses: USB first (lowest latency, no pairing), then Wi-Fi, then manual.
 */
data class HostGroup(val primary: DiscoveredHost, val members: List<DiscoveredHost>) {
    val key: String get() = primary.id
    val name: String get() = primary.name
    val transports: List<Transport> get() = members.map { it.transport }.distinct().sortedBy(::rank)
    val virtualDisplay: Boolean get() = members.any { it.virtualDisplay }
    /** First non-loopback address, for the subtitle ("192.168.1.24"). */
    val lanAddress: String? get() = members.firstOrNull { it.transport != Transport.USB }?.address

    fun contains(host: DiscoveredHost?): Boolean = host != null && members.any { it.id == host.id }

    companion object {
        private fun rank(t: Transport) = when (t) {
            Transport.USB -> 0
            Transport.WIFI -> 1
            Transport.MANUAL -> 2
        }

        private fun normalizedName(h: DiscoveredHost) = h.name.trim().lowercase()

        fun merge(hosts: List<DiscoveredHost>): List<HostGroup> {
            // 1) Same id → same computer.
            val byId = LinkedHashMap<String, MutableList<DiscoveredHost>>()
            for (h in hosts) byId.getOrPut(h.id) { mutableListOf() }.add(h)
            val groups = byId.values.map { it.toMutableList() }.toMutableList()
            // 2) The USB entry carries the last host name seen over USB: fold it into the network
            //    entry with the same computer name (the host advertises the same name on both).
            val usb = groups.firstOrNull { g -> g.any { it.transport == Transport.USB } }
            if (usb != null) {
                val usbName = usb.firstOrNull { it.transport == Transport.USB }?.let(::normalizedName)
                val twin = groups.firstOrNull { g ->
                    g !== usb && usbName != null && usbName != "usb" &&
                        usbName != HostDiscovery.UNKNOWN_USB_NAME.lowercase() && g.any { normalizedName(it) == usbName }
                }
                if (twin != null) {
                    usb.addAll(twin)
                    groups.remove(twin)
                }
            }
            return groups.map { members ->
                val sorted = members.sortedBy { rank(it.transport) }
                HostGroup(sorted.first(), sorted)
            }
        }
    }
}
