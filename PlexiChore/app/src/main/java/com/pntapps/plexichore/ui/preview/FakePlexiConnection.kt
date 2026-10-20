package com.pntapps.plexichore.ui.preview

import com.pntapps.plexichore.core.ConnectionState
import com.pntapps.plexichore.core.DiscoveredHost
import com.pntapps.plexichore.core.DisplayMode
import com.pntapps.plexichore.core.PlexiConnection
import com.pntapps.plexichore.core.StreamConfig
import com.pntapps.plexichore.core.StreamSettings
import com.pntapps.plexichore.core.StreamStats
import com.pntapps.plexichore.core.Transport
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * Simulated connection used for Compose previews and the in-app "Demo mode".
 * Hosts appear one by one; connecting walks through Connecting -> AwaitingApproval (Wi-Fi) ->
 * Streaming. The host named "Studio-iMac" always fails so the error state can be seen.
 */
class FakePlexiConnection : PlexiConnection {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val _state = MutableStateFlow<ConnectionState>(ConnectionState.Idle)
    private val _hosts = MutableStateFlow<List<DiscoveredHost>>(emptyList())
    private val _stats = MutableStateFlow(StreamStats())
    override val state: StateFlow<ConnectionState> = _state
    override val hosts: StateFlow<List<DiscoveredHost>> = _hosts
    override val stats: StateFlow<StreamStats> = _stats

    private var discoveryJob: Job? = null
    private var connectJob: Job? = null

    override fun startDiscovery() {
        if (discoveryJob?.isActive == true) return
        discoveryJob = scope.launch {
            delay(2200)
            sample.forEachIndexed { i, h ->
                _hosts.value = sample.take(i + 1).map { it.copy(lastSeenMs = System.currentTimeMillis()) }
                delay(900)
            }
        }
    }

    override fun stopDiscovery() {
        discoveryJob?.cancel()
    }

    override fun connect(host: DiscoveredHost, settings: StreamSettings) {
        connectJob?.cancel()
        connectJob = scope.launch {
            _state.value = ConnectionState.Connecting(host)
            delay(1800)
            if (host.name == "Studio-iMac") {
                _state.value = ConnectionState.Failed(host, "The computer refused the connection. Make sure PlexiChore Desktop is running and allowed through the firewall.")
                return@launch
            }
            if (host.transport != Transport.USB) {
                _state.value = ConnectionState.AwaitingApproval(host, "4821")
                delay(6000)
            }
            _state.value = ConnectionState.Streaming(
                host,
                StreamConfig("h264", 2560, 1600, settings.fps, settings.bitrateKbps, settings.mode, host.name, host.os, host.virtualDisplay),
            )
        }
    }

    override fun connectManual(ip: String, port: Int, settings: StreamSettings) {
        connect(
            DiscoveredHost("manual-$ip", ip, "windows", ip, port, Transport.MANUAL, true, System.currentTimeMillis()),
            settings,
        )
    }

    override fun updateSettings(settings: StreamSettings) = Unit

    override fun disconnect() {
        connectJob?.cancel()
        _state.value = ConnectionState.Idle
    }

    companion object {
        val sample = listOf(
            DiscoveredHost("usb", "DESIGN-WORKSTATION", "windows", "127.0.0.1", 47800, Transport.USB, true, 0),
            DiscoveredHost("mbp", "Studio MacBook Pro", "macos", "192.168.1.24", 47800, Transport.WIFI, true, 0),
            DiscoveredHost("imac", "Studio-iMac", "macos", "192.168.1.40", 47800, Transport.WIFI, false, 0),
        )
        val sampleConfig = StreamConfig("h264", 2560, 1600, 60, 20000, DisplayMode.EXTEND, "DESIGN-WORKSTATION", "windows", true)
    }
}
