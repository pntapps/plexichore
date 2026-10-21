package com.pntapps.plexichore.core

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/** Entry point for the UI layer. */
object PlexiCore {
    @Volatile private var instance: PlexiCoreConnection? = null

    @JvmStatic
    fun get(context: Context): PlexiConnection = impl(context)

    internal fun impl(context: Context): PlexiCoreConnection =
        instance ?: synchronized(this) {
            instance ?: PlexiCoreConnection(context.applicationContext).also { instance = it }
        }
}

/**
 * Process-wide connection manager: discovery, one streaming session at a time with automatic
 * reconnection, the video pipeline and stats. The session outlives activities; [StreamService]
 * keeps the process in the foreground while connected.
 */
internal class PlexiCoreConnection(private val app: Context) : PlexiConnection, VideoPipeline.Listener {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val main = Handler(Looper.getMainLooper())

    private val _state = MutableStateFlow<ConnectionState>(ConnectionState.Idle)
    override val state: StateFlow<ConnectionState> = _state.asStateFlow()

    private val _stats = MutableStateFlow(StreamStats())
    override val stats: StateFlow<StreamStats> = _stats.asStateFlow()

    private val _settings = MutableStateFlow(StreamSettings())
    /** Settings of the current/last connection (incl. local-only flags such as the stats overlay). */
    val settings: StateFlow<StreamSettings> = _settings.asStateFlow()

    val pipeline = VideoPipeline(this)
    @Volatile private var connectStartMs = 0L
    @Volatile private var lanRedirect = false

    @Volatile private var currentHost: DiscoveredHost? = null
    @Volatile private var session: StreamSession? = null
    @Volatile private var codecFallback: String? = null
    @Volatile private var generation = 0
    private var connectJob: Job? = null
    private var displayLaunched = false
    /** Host as last shown while streaming (real name from CONFIG), used for reconnect/fail states. */
    @Volatile private var shownHost: DiscoveredHost? = null
    private val lock = Any()

    init { LanNetwork.init(app) }

    private val displayLauncher = DisplayLauncher(app, main) { _state.value is ConnectionState.Streaming }

    private val discovery = HostDiscovery(app, scope) { currentHost }
    override val hosts: StateFlow<List<DiscoveredHost>> = discovery.hosts

    /** Rebuilt for every connection: fold/unfold, DeX and resolution changes alter size, density and decoder caps. */
    @Volatile private var profileCache: DeviceProfile? = null
    private val profile: DeviceProfile get() = profileCache ?: DeviceProfile.build(app).also { profileCache = it }

    /** "landscape" / "portrait" as last reported to the host, and the display window size in px. */
    @Volatile private var orientation = Protocol.ORIENTATION_LANDSCAPE
    @Volatile private var viewport: Pair<Int, Int>? = null
    private val orientationSender = Runnable { sendOrientation() }

    override fun startDiscovery() = discovery.start()

    override fun stopDiscovery() = discovery.stop()

    override fun connect(host: DiscoveredHost, settings: StreamSettings) {
        synchronized(lock) {
            teardownLocked("switching host")
            val gen = generation
            _settings.value = settings
            codecFallback = null
            profileCache = null
            initialOrientation()
            currentHost = host
            displayLaunched = false
            shownHost = null
            _stats.value = StreamStats()
            _state.value = ConnectionState.Connecting(host)
            StreamService.start(app, host.name)
            connectStartMs = SystemClock.elapsedRealtime()
            pipeline.onFirstFrame = {
                val t = connectStartMs
                if (t > 0) {
                    connectStartMs = 0L
                    Log.i(TAG, "First frame on screen ${SystemClock.elapsedRealtime() - t} ms after connect()")
                }
            }
            connectJob = scope.launch { runConnection(host, gen) }
        }
    }

    override fun connectManual(ip: String, port: Int, settings: StreamSettings) {
        val address = ip.trim().removePrefix("tcp://").substringBefore('/')
        val loopback = address == HostDiscovery.LOOPBACK || address.equals("localhost", true)
        val host = if (loopback) {
            val (name, os) = HostDiscovery.lastUsbHost(app)
            DiscoveredHost(HostDiscovery.USB_ID, name, os, HostDiscovery.LOOPBACK, port, Transport.USB, true, System.currentTimeMillis())
        } else {
            DiscoveredHost("manual:$address:$port", address, "unknown", address, port, Transport.MANUAL, false, System.currentTimeMillis())
        }
        connect(host, settings)
    }

    override fun updateSettings(settings: StreamSettings) {
        val old = _settings.value
        _settings.value = settings
        if (settings.codec != old.codec) codecFallback = null
        val hostRelevant = old.copy(keepScreenOn = settings.keepScreenOn, showStatsOverlay = settings.showStatsOverlay) != settings
        if (hostRelevant) session?.send(Protocol.frame(Protocol.SETTINGS, Protocol.requested(settings, requestedCodec(), orientation)))
    }

    override fun disconnect() {
        synchronized(lock) {
            teardownLocked("user disconnected")
            currentHost = null
            _state.value = ConnectionState.Idle
            _stats.value = StreamStats()
            StreamService.stop(app)
        }
    }

    /** Forwards an encoded pointer event if streaming and touch forwarding is enabled. */
    fun sendInput(input: EncodedInput) {
        if (_settings.value.touchMode == TouchMode.NONE) return
        if (_state.value !is ConnectionState.Streaming) return
        session?.send(input.frame, input.coalesceKey)
    }

    // VideoPipeline.Listener
    override fun requestKeyframe() {
        session?.requestKeyframe()
    }

    override fun onCodecUnavailable(codec: String) {
        Log.w(TAG, "$codec decoding unavailable, asking host for MJPEG")
        codecFallback = VideoPipeline.CODEC_MJPEG
        // Software JPEG decode of a full 2.5K frame runs at ~15 fps on mid-range SoCs: ask for at most
        // ~1920 px on the long edge and 30 fps, so the fallback stays usable.
        val s = _settings.value
        val longEdge = profile.widthPx.coerceAtLeast(1)
        val scale = minOf(s.resolutionScale, 1920f / longEdge).coerceIn(0.5f, 1f)
        session?.send(
            Protocol.frame(
                Protocol.SETTINGS,
                org.json.JSONObject()
                    .put("codec", VideoPipeline.CODEC_MJPEG)
                    .put("resolutionScale", scale.toDouble())
                    .put("fps", minOf(s.fps, 30)),
            ),
        )
    }

    /**
     * Called by the display with its window size whenever it changes (rotation, split screen,
     * fold/unfold). On large screens the stream follows the tablet's orientation: the host is told
     * after the size has been stable for a moment, so a rotation animation does not reconfigure twice.
     */
    fun onViewportChanged(widthPx: Int, heightPx: Int) {
        if (widthPx <= 0 || heightPx <= 0) return
        viewport = widthPx to heightPx
        val wanted = orientationFor(widthPx, heightPx)
        main.removeCallbacks(orientationSender)
        if (wanted != orientation) main.postDelayed(orientationSender, ORIENTATION_SETTLE_MS)
    }

    /** True when the tablet is held portrait but the host sent a landscape stream (e.g. no portrait mode on the PC). */
    fun orientationMismatch(config: StreamConfig): Boolean {
        val vp = viewport ?: return false
        if (!largeScreen()) return false
        val viewPortrait = vp.second > vp.first
        val streamPortrait = config.height > config.width
        return viewPortrait != streamPortrait && config.mode != DisplayMode.MIRROR
    }

    private fun orientationFor(w: Int, h: Int): String =
        if (largeScreen() && h > w * 1.05f) Protocol.ORIENTATION_PORTRAIT else Protocol.ORIENTATION_LANDSCAPE

    /** sw >= 600dp: Android 16+ ignores our landscape lock there, so the stream must follow the tablet. */
    private fun largeScreen(): Boolean = app.resources.configuration.smallestScreenWidthDp >= 600

    private fun initialOrientation() {
        runCatching {
            val m = app.resources.displayMetrics
            viewport = m.widthPixels to m.heightPixels
            orientation = orientationFor(m.widthPixels, m.heightPixels)
        }
    }

    private fun sendOrientation() {
        val vp = viewport ?: return
        val wanted = orientationFor(vp.first, vp.second)
        if (wanted == orientation) return
        orientation = wanted
        Log.i(TAG, "Orientation now $wanted (${vp.first}x${vp.second})")
        session?.send(Protocol.frame(Protocol.SETTINGS, org.json.JSONObject().put("orientation", wanted)))
    }

    private fun requestedCodec(): String {
        val wanted = codecFallback ?: _settings.value.codec.lowercase()
        return if (wanted in profile.codecs) wanted else VideoPipeline.CODEC_MJPEG
    }

    private fun teardownLocked(byeReason: String) {
        generation++
        main.post { displayLauncher.cancel() }
        connectJob?.cancel()
        connectJob = null
        val s = session
        session = null
        // Socket I/O must stay off the main thread.
        if (s != null) scope.launch(Dispatchers.IO) { s.close(byeReason) }
        pipeline.setConfig(null)
    }

    /** Applies a terminal state for connection [gen], unless a newer connect()/disconnect() won. */
    private fun finish(gen: Int, terminal: ConnectionState) {
        synchronized(lock) {
            if (gen != generation) return
            generation++
            connectJob = null
            currentHost = null
            _state.value = terminal
            StreamService.stop(app)
        }
    }

    /**
     * The "USB" entry (127.0.0.1 via adb reverse) may actually be tunnelled over *wireless* debugging: no cable to a
     * PC, wireless debugging on. adbd then adds ~15-25 ms RTT and bunches frames; the same PC's direct LAN path is
     * clearly better (measured on a Tab S8: RTT 5-8 ms vs 18-27 ms, fewer late frames). Returns that Wi-Fi entry.
     */
    private fun lanAlternative(h: DiscoveredHost): DiscoveredHost? {
        if (h.transport != Transport.USB) return null
        return runCatching {
            val battery = app.registerReceiver(null, android.content.IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED))
            val plugged = battery?.getIntExtra(android.os.BatteryManager.EXTRA_PLUGGED, 0) ?: 0
            val cableToPc = plugged == android.os.BatteryManager.BATTERY_PLUGGED_USB
            val wirelessAdb = android.provider.Settings.Global.getInt(app.contentResolver, "adb_wifi_enabled", 0) == 1
            if (cableToPc || !wirelessAdb) return null
            val name = HostDiscovery.lastUsbHost(app).first
            hosts.value.firstOrNull { it.transport == Transport.WIFI && it.name.equals(name, ignoreCase = true) }
        }.getOrNull()
    }

    private suspend fun runConnection(requested: DiscoveredHost, gen: Int) = coroutineScope {
        val statsJob = launch { statsLoop() }
        var failures = 0
        var everStreamed = false
        // prefer the direct LAN path over adb-over-Wi-Fi; fall back to the requested route if it does not work out
        lanRedirect = false
        var host = lanAlternative(requested)?.also {
            Log.i(TAG, "USB host is reached over wireless debugging; using the direct Wi-Fi path ${it.address} instead")
            lanRedirect = true
            currentHost = it
        } ?: requested
        try {
            while (isActive && gen == generation) {
                val s = StreamSession(host, Protocol.hello(profile, _settings.value, requestedCodec(), orientation, viewport), pipeline, sessionEvents(host, gen))
                val current = synchronized(lock) {
                    if (gen != generation) false else {
                        session = s
                        true
                    }
                }
                if (!current) break
                val pinger = launch {
                    while (isActive) {
                        delay(PING_INTERVAL_MS)
                        s.sendPing()
                    }
                }
                val end = withContext(Dispatchers.IO) { s.run() }
                pinger.cancel()
                synchronized(lock) { if (session === s) session = null }
                if (!isActive || gen != generation) break
                pipeline.setConfig(null)
                Log.i(TAG, "Session with ${host.address} ended: $end")
                if (host !== requested && !s.gotConfig) {
                    lanRedirect = false
                    Log.i(TAG, "Direct Wi-Fi path failed ($end); using ${requested.address}")
                    host = requested
                    currentHost = requested
                    continue
                }
                when (end) {
                    SessionEnd.Closed -> break
                    is SessionEnd.HostBye -> {
                        val why = end.reason.takeIf { it.isNotBlank() }?.let { ": $it" } ?: ""
                        finish(gen, ConnectionState.Failed(shownHost ?: host, "${hostLabel(host)} ended the session$why"))
                        break
                    }
                    SessionEnd.Rejected -> {
                        finish(gen, ConnectionState.Failed(shownHost ?: host, "The connection was declined on ${hostLabel(host)}"))
                        break
                    }
                    is SessionEnd.Error -> {
                        if (s.gotConfig) {
                            everStreamed = true
                            failures = 0
                        }
                        failures++
                        val limit = if (everStreamed) MAX_RECONNECTS else INITIAL_RETRIES
                        if (failures > limit) {
                            finish(gen, ConnectionState.Failed(shownHost ?: host, describe(host, end, everStreamed)))
                            break
                        }
                        if (gen == generation) _state.value = ConnectionState.Connecting(shownHost ?: host)
                        delay(backoffMs(failures))
                    }
                }
            }
        } catch (e: CancellationException) {
            throw e
        } finally {
            statsJob.cancel()
        }
    }

    private fun sessionEvents(host: DiscoveredHost, gen: Int) = object : StreamSession.Events {
        override fun onPairing(status: String, code: String) {
            if (gen != generation) return
            if (status == "waiting" && lanRedirect) {
                // not trusted on Wi-Fi yet: do not make the user approve a path they did not pick, go back to USB
                Log.i(TAG, "Direct Wi-Fi path needs approval; staying on the USB route")
                lanRedirect = false
                session?.let { s -> scope.launch(Dispatchers.IO) { s.close("using usb") } }
                return
            }
            when (status) {
                "waiting" -> _state.value = ConnectionState.AwaitingApproval(host, code)
                "approved" -> _state.value = ConnectionState.Connecting(host)
            }
        }

        override fun onConfig(config: StreamConfig) {
            val t0 = connectStartMs
            if (t0 > 0) Log.i(TAG, "CONFIG ${config.width}x${config.height} ${config.mode} ${SystemClock.elapsedRealtime() - t0} ms after connect()")
            synchronized(lock) {
                if (gen != generation) return
                val shown = if (host.transport == Transport.WIFI) host
                else host.copy(name = config.hostName, os = config.hostOs)
                shownHost = shown
                _state.value = ConnectionState.Streaming(shown, config)
                if (host.transport == Transport.USB && config.link.isNotEmpty()) HostDiscovery.lastUsbLink = config.link
                if (host.transport == Transport.USB) HostDiscovery.rememberUsbHost(app, config.hostName, config.hostOs)
                else HostDiscovery.rememberLanHost(app, host.address)
                StreamService.update(app, config.hostName)
                if (!displayLaunched) {
                    displayLaunched = true
                    main.post { launchDisplay() }
                }
            }
        }
    }

    private fun launchDisplay() = displayLauncher.request()

    private suspend fun statsLoop() {
        var lastT = SystemClock.elapsedRealtimeNanos()
        var lastRendered = pipeline.rendered.get()
        var lastDecode = pipeline.decodeNanos.get()
        val droppedBase = pipeline.dropped.get()
        var lastBytes = 0L
        var lastSession: StreamSession? = null
        while (true) {
            delay(1_000)
            val now = SystemClock.elapsedRealtimeNanos()
            val dt = (now - lastT) / 1e9f
            lastT = now
            val s = session
            if (s !== lastSession) {
                lastSession = s
                lastBytes = 0L
            }
            val bytes = s?.videoBytes?.get() ?: 0L
            val rendered = pipeline.rendered.get()
            val decode = pipeline.decodeNanos.get()
            val frames = rendered - lastRendered
            _stats.value = StreamStats(
                fps = if (dt > 0) frames / dt else 0f,
                rttMs = s?.rttMs ?: 0f,
                bitrateKbps = if (dt > 0) ((bytes - lastBytes) * 8 / 1000f / dt).toInt().coerceAtLeast(0) else 0,
                decodeMs = if (frames > 0) (decode - lastDecode) / frames / 1e6f else 0f,
                droppedFrames = pipeline.dropped.get() - droppedBase,
            )
            if (frames > 0 || s != null) {
                val st = _stats.value
                Log.i(STATS_TAG, "fps=%.1f rtt=%.1fms kbps=%d decode=%.1fms dropped=%d maxGap=%.1fms hitches=%d netGap=%.1fms pace=%.0fms lead=%.1fms via %s".format(
                    st.fps, st.rttMs, st.bitrateKbps, st.decodeMs, st.droppedFrames, pipeline.takeMaxGapNanos() / 1e6,
                    pipeline.hitches.getAndSet(0), (s?.takeMaxArrivalGapNanos() ?: 0L) / 1e6, pipeline.pacingDelayMs(), pipeline.pacingLeadMs(),
                    currentHost?.let { "${linkLabel(it)} ${it.address}" } ?: "-"))
            }
            lastRendered = rendered
            lastDecode = decode
            lastBytes = bytes
        }
    }

    /** Transport as shown in stats: the host's CONFIG `link` (cable vs wireless debugging behind 127.0.0.1) when known. */
    private fun linkLabel(h: DiscoveredHost): String {
        val link = (_state.value as? ConnectionState.Streaming)?.config?.link.orEmpty()
        return when {
            h.usbNetwork -> "USB-NET"
            h.transport != Transport.USB || link.isEmpty() -> h.transport.name
            link == "usb-wireless-adb" -> "USB-ADB-WIFI"
            else -> h.transport.name
        }
    }

    private fun hostLabel(host: DiscoveredHost): String =
        shownHost?.name ?: host.name

    private fun describe(host: DiscoveredHost, end: SessionEnd.Error, everStreamed: Boolean): String {
        val e = end.error
        return when {
            everStreamed -> "Lost connection to ${hostLabel(host)}"
            e is UnknownHostException -> "Unknown address ${host.address}"
            host.transport != Transport.USB && !HostDiscovery.hasLocalNetworkAccess(app) ->
                "Allow Wi-Fi discovery (local network access) for PlexiChore to connect over Wi-Fi. USB works without it."
            host.transport != Transport.USB && (e.message?.contains("EPERM") == true || e.message?.contains("not permitted", true) == true) ->
                "Android blocked the connection to ${host.address}. Allow local network access for PlexiChore in Settings."
            host.transport == Transport.USB && (!end.connected || e is java.io.EOFException) ->
                "No PlexiChore host on USB. Make sure the desktop app is running and the cable is connected."
            e is ConnectException -> "${host.name} refused the connection. Is PlexiChore running on the computer?"
            e is SocketTimeoutException -> "${host.name} is not responding"
            e is NoRouteToHostException -> "Cannot reach ${host.address}. Check that both devices are on the same network."
            else -> "Could not connect to ${host.name}: ${e.message ?: e.javaClass.simpleName}"
        }
    }

    private fun backoffMs(attempt: Int): Long = when (attempt) {
        1 -> 300L
        2 -> 700L
        3 -> 1_500L
        else -> 2_500L
    }

    companion object {
        private const val TAG = "PlexiCore"
        private const val STATS_TAG = "PlexiStats"
        private const val PING_INTERVAL_MS = 1_000L
        private const val INITIAL_RETRIES = 1
        private const val MAX_RECONNECTS = 8
        private const val ORIENTATION_SETTLE_MS = 700L
    }
}
