package com.pntapps.plexichore.core

import android.content.Context
import android.net.wifi.WifiManager
import android.os.SystemClock
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.ConcurrentHashMap

/**
 * Finds hosts via UDP beacons / `PLEXI?` probes on 47801 and via adb-reverse on
 * 127.0.0.1:47800 (USB). Entries unseen for [STALE_MS] are pruned.
 */
internal class HostDiscovery(
    private val context: Context,
    private val scope: CoroutineScope,
    /** Address of the host we are currently streaming from, if any (never probed while busy). */
    private val activeHost: () -> DiscoveredHost?,
) {
    private val table = ConcurrentHashMap<String, DiscoveredHost>()
    private val _hosts = MutableStateFlow<List<DiscoveredHost>>(emptyList())
    val hosts: StateFlow<List<DiscoveredHost>> = _hosts.asStateFlow()

    private var job: Job? = null

    @Synchronized
    fun start() {
        if (job?.isActive == true) return
        job = scope.launch(Dispatchers.IO) {
            launch { udpLoop() }
            launch { usbLoop() }
            while (isActive) {
                prune()
                delay(1_000)
            }
        }
    }

    @Synchronized
    fun stop() {
        job?.cancel()
        job = null
        table.clear()
        publish()
    }

    private suspend fun udpLoop() {
        val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
        val lock = wifi?.createMulticastLock("plexichore-discovery")?.apply { setReferenceCounted(false) }
        try {
            runCatching { lock?.acquire() }
            while (currentCoroutineContext().isActive) {
                // Android 17+: LAN traffic needs ACCESS_LOCAL_NETWORK (the UI asks for it); wait for it
                // instead of spinning on EPERM. USB discovery (loopback) keeps running meanwhile.
                if (!hasLocalNetworkAccess(context)) {
                    delay(2_000)
                    continue
                }
                val socket = try {
                    openSocket()
                } catch (e: Exception) {
                    Log.w(TAG, "UDP socket failed: ${e.message}")
                    delay(2_000)
                    continue
                }
                try {
                    receiveLoop(socket)
                } finally {
                    socket.close()
                }
            }
        } finally {
            runCatching { if (lock?.isHeld == true) lock.release() }
        }
    }

    private fun openSocket(): DatagramSocket {
        val s = DatagramSocket(null)
        s.reuseAddress = true
        s.broadcast = true
        s.soTimeout = 250
        try {
            s.bind(InetSocketAddress(Protocol.UDP_PORT))
        } catch (e: Exception) {
            // Port busy: still discover via probe replies on an ephemeral port.
            Log.w(TAG, "Port ${Protocol.UDP_PORT} busy, using ephemeral port", e)
            s.close()
            return DatagramSocket().apply {
                broadcast = true
                soTimeout = 250
                LanNetwork.bindIfVpn(this)
            }
        }
        LanNetwork.bindIfVpn(s)
        return s
    }

    private suspend fun receiveLoop(socket: DatagramSocket) {
        val buf = ByteArray(2048)
        val packet = DatagramPacket(buf, buf.size)
        var nextProbe = 0L
        val started = SystemClock.elapsedRealtime()
        var nextSweep = started + SWEEP_AFTER_MS
        var sweep: Iterator<InetAddress>? = null
        while (currentCoroutineContext().isActive) {
            val now = SystemClock.elapsedRealtime()
            if (now >= nextProbe) {
                sendProbes(socket)
                nextProbe = now + PROBE_INTERVAL_MS
            }
            // Many APs (client isolation, "multicast/broadcast enhancement", mesh, hotel/enterprise
            // Wi-Fi) drop broadcasts. If nothing answered, probe every address of our own subnet by
            // unicast, a small batch per loop so receiving is never blocked for long.
            if (sweep == null && now >= nextSweep) {
                nextSweep = now + SWEEP_INTERVAL_MS
                if (table.values.none { it.transport == Transport.WIFI }) {
                    sweep = sweepTargets().iterator()
                }
            }
            sweep?.let { it ->
                val probe = Protocol.PROBE.toByteArray(Charsets.US_ASCII)
                var n = 0
                while (n < SWEEP_BATCH && it.hasNext()) {
                    runCatching { socket.send(DatagramPacket(probe, probe.size, it.next(), Protocol.UDP_PORT)) }
                    n++
                }
                if (!it.hasNext()) sweep = null
            }
            try {
                packet.setLength(buf.size)
                socket.receive(packet)
                handlePacket(packet)
            } catch (_: SocketTimeoutException) {
            } catch (e: Exception) {
                if (!currentCoroutineContext().isActive) return
                Log.w(TAG, "UDP receive failed: ${e.message}")
                delay(1_000)
                return // reopen socket
            }
        }
    }

    private fun sendProbes(socket: DatagramSocket) {
        val probe = Protocol.PROBE.toByteArray(Charsets.US_ASCII)
        val targets = LinkedHashSet<InetAddress>(broadcastAddresses())
        // The last computer we streamed from over the LAN is probed directly every round.
        lastLanHost(context)?.let { ip -> runCatching { InetAddress.getByName(ip) }.getOrNull()?.let(targets::add) }
        for (addr in targets) {
            runCatching { socket.send(DatagramPacket(probe, probe.size, addr, Protocol.UDP_PORT)) }
        }
    }

    /** Wi-Fi / Ethernet interfaces only: cellular, VPN tunnels and CLAT add noise (and can cost data). */
    private fun lanInterfaces(): List<NetworkInterface> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList().filter { nif ->
            val n = nif.name.lowercase()
            nif.isUp && !nif.isLoopback && !nif.isPointToPoint &&
                NON_LAN_PREFIXES.none { n.startsWith(it) }
        }
    }.getOrDefault(emptyList())

    private fun broadcastAddresses(): Set<InetAddress> {
        val out = LinkedHashSet<InetAddress>()
        out.add(InetAddress.getByAddress(byteArrayOf(-1, -1, -1, -1)))
        for (nif in lanInterfaces()) {
            for (ia in nif.interfaceAddresses) {
                if (ia.address is Inet4Address) ia.broadcast?.let { out.add(it) }
            }
        }
        return out
    }

    /** Every host address of our own IPv4 subnet(s), capped at a /24 around our address. */
    private fun sweepTargets(): List<InetAddress> {
        val out = ArrayList<InetAddress>()
        for (nif in lanInterfaces()) {
            for (ia in nif.interfaceAddresses) {
                val a = ia.address as? Inet4Address ?: continue
                if (a.isLinkLocalAddress) continue
                val prefix = ia.networkPrefixLength.toInt().coerceIn(24, 30)
                val ip = a.address.fold(0) { acc, b -> (acc shl 8) or (b.toInt() and 0xFF) }
                val mask = -1 shl (32 - prefix)
                val net = ip and mask
                val count = (1 shl (32 - prefix)) - 2
                for (i in 1..count) {
                    val v = net + i
                    if (v == ip) continue
                    out.add(InetAddress.getByAddress(byteArrayOf((v ushr 24).toByte(), (v ushr 16).toByte(), (v ushr 8).toByte(), v.toByte())))
                }
            }
        }
        if (out.isNotEmpty()) Log.i(TAG, "No host answered broadcasts; unicast probing ${out.size} addresses")
        return out
    }

    private fun handlePacket(packet: DatagramPacket) {
        if (packet.length < 2 || packet.data[packet.offset].toInt() != '{'.code) return // e.g. our own PLEXI?
        val json = runCatching {
            JSONObject(String(packet.data, packet.offset, packet.length, Charsets.UTF_8))
        }.getOrNull() ?: return
        if (json.optString("svc") != "plexichore") return
        val id = json.optString("id").ifBlank { return }
        val address = packet.address?.hostAddress ?: return
        val host = DiscoveredHost(
            id = id,
            name = json.optString("name").ifBlank { address },
            os = json.optString("os", "windows"),
            address = address,
            port = json.optInt("port", Protocol.TCP_PORT),
            transport = Transport.WIFI,
            virtualDisplay = json.optBoolean("virtualDisplay", false),
            lastSeenMs = System.currentTimeMillis(),
            usbNetwork = isUsbNetworkAddress(packet.address),
        )
        // The same PC on Wi-Fi *and* on the USB-tethering link (cable): keep the cable while it is alive - lower and
        // steadier latency than Wi-Fi, no adb in the path.
        val cur = table[id]
        if (cur != null && cur.usbNetwork && !host.usbNetwork && System.currentTimeMillis() - cur.lastSeenMs < STALE_MS) return
        val prev = table.put(id, host)
        if (prev == null || prev.address != host.address || prev.name != host.name ||
            prev.virtualDisplay != host.virtualDisplay || prev.port != host.port
        ) publish()
    }

    /** True when [addr] is on the subnet of a USB-tethering interface (rndis0 / ncm0 / usb0) of this tablet. */
    private fun isUsbNetworkAddress(addr: InetAddress?): Boolean {
        val a = addr as? Inet4Address ?: return false
        return runCatching {
            NetworkInterface.getNetworkInterfaces().toList().any { nif ->
                val n = nif.name.lowercase()
                nif.isUp && USB_NET_PREFIXES.any { n.startsWith(it) } && nif.interfaceAddresses.any { ia ->
                    val la = ia.address as? Inet4Address ?: return@any false
                    val prefix = ia.networkPrefixLength.toInt().coerceIn(8, 32)
                    val mask = if (prefix == 32) -1 else (-1 shl (32 - prefix))
                    (toInt(la) and mask) == (toInt(a) and mask)
                }
            }
        }.getOrDefault(false)
    }

    private fun toInt(a: Inet4Address): Int = a.address.fold(0) { acc, b -> (acc shl 8) or (b.toInt() and 0xFF) }

    private suspend fun usbLoop() {
        while (currentCoroutineContext().isActive) {
            val active = activeHost()
            val alive = if (active?.transport == Transport.USB) true else probeUsb()
            if (alive) {
                val prev = table[USB_ID]
                val (name, os) = lastUsbHost(context)
                table[USB_ID] = DiscoveredHost(
                    id = USB_ID,
                    name = name,
                    os = os,
                    address = LOOPBACK,
                    port = Protocol.TCP_PORT,
                    transport = Transport.USB,
                    virtualDisplay = prev?.virtualDisplay ?: true,
                    lastSeenMs = System.currentTimeMillis(),
                )
                if (prev == null || prev.name != name) publish()
            }
            delay(USB_PROBE_INTERVAL_MS)
        }
    }

    /**
     * adb-reverse accepts the local connection even if nothing listens on the PC, then closes it.
     * So we connect, send nothing, and treat "still open after a moment" as a live host.
     */
    private fun probeUsb(): Boolean = try {
        Socket().use { s ->
            s.connect(InetSocketAddress(LOOPBACK, Protocol.TCP_PORT), 300)
            s.soTimeout = 250
            try {
                s.getInputStream().read() >= 0 // a host may legitimately talk first
            } catch (_: SocketTimeoutException) {
                true
            }
        }
    } catch (_: Exception) {
        false
    }

    private fun prune() {
        val cutoff = System.currentTimeMillis() - STALE_MS
        val active = activeHost()
        val removed = table.entries.removeIf { it.value.lastSeenMs < cutoff && it.value.id != active?.id }
        if (removed || table.isNotEmpty()) publish()
    }

    private fun publish() {
        val list = table.values.sortedWith(
            compareBy<DiscoveredHost>({ it.transport != Transport.USB }, { it.name.lowercase() }, { it.address })
        )
        if (list.map { it.id to it.address } != _hosts.value.map { it.id to it.address }) {
            Log.d(TAG, "Hosts: " + list.joinToString { "${it.name} [${it.transport} ${it.address}:${it.port}]" })
        }
        _hosts.value = list
    }

    companion object {
        private const val TAG = "PlexiDiscovery"
        const val USB_ID = "usb"
        const val LOOPBACK = "127.0.0.1"
        private const val STALE_MS = 4_000L
        private const val PROBE_INTERVAL_MS = 1_000L
        private const val USB_PROBE_INTERVAL_MS = 1_000L
        private const val KEY_USB_NAME = "usb_host_name"
        private const val KEY_USB_OS = "usb_host_os"

        /** CONFIG `link` of the last USB (127.0.0.1) session: "usb-cable" or "usb-wireless-adb"; "" = unknown. */
        @Volatile var lastUsbLink: String = ""

        /**
         * The 127.0.0.1 "USB" route is tunnelled over *wireless debugging* rather than a cable: nothing plugged into a
         * computer (a charger doesn't count) and wireless debugging is on. Used for labels and the LAN-path preference.
         */
        fun usbIsWirelessDebugging(context: Context): Boolean = runCatching {
            val battery = context.registerReceiver(null, android.content.IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED))
            val plugged = battery?.getIntExtra(android.os.BatteryManager.EXTRA_PLUGGED, 0) ?: 0
            val cableToPc = plugged == android.os.BatteryManager.BATTERY_PLUGGED_USB
            val wirelessAdb = android.provider.Settings.Global.getInt(context.contentResolver, "adb_wifi_enabled", 0) == 1
            !cableToPc && wirelessAdb
        }.getOrDefault(false)

        /** Card title for a USB host before any USB session told us its name (OS left blank, not guessed). */
        const val UNKNOWN_USB_NAME = "Computer on USB"

        fun lastUsbHost(context: Context): Pair<String, String> {
            val p = DeviceProfile.prefs(context)
            return (p.getString(KEY_USB_NAME, null) ?: UNKNOWN_USB_NAME) to (p.getString(KEY_USB_OS, null) ?: "")
        }

        fun rememberUsbHost(context: Context, name: String, os: String) {
            DeviceProfile.prefs(context).edit().putString(KEY_USB_NAME, name).putString(KEY_USB_OS, os).apply()
        }

        private const val KEY_LAN_HOST = "last_lan_host"
        private const val SWEEP_AFTER_MS = 4_000L
        private const val SWEEP_INTERVAL_MS = 15_000L
        private const val SWEEP_BATCH = 32
        private val USB_NET_PREFIXES = listOf("rndis", "ncm", "usb")
        private val NON_LAN_PREFIXES = listOf("rmnet", "ccmni", "tun", "ppp", "dummy", "clat", "v4-", "ip6tnl", "ipsec", "seth", "radio")

        /** API 37+ Local Network Protection; always true below 37. */
        fun hasLocalNetworkAccess(context: Context): Boolean =
            android.os.Build.VERSION.SDK_INT < 37 ||
                context.checkSelfPermission("android.permission.ACCESS_LOCAL_NETWORK") == android.content.pm.PackageManager.PERMISSION_GRANTED

        fun lastLanHost(context: Context): String? = DeviceProfile.prefs(context).getString(KEY_LAN_HOST, null)

        /** Remembered after a successful Wi-Fi / manual session; probed by unicast on every discovery round. */
        fun rememberLanHost(context: Context, address: String) {
            if (address == LOOPBACK) return
            DeviceProfile.prefs(context).edit().putString(KEY_LAN_HOST, address).apply()
        }
    }
}
