package com.pntapps.plexichore.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.pntapps.plexichore.core.ConnectionState
import com.pntapps.plexichore.core.DiscoveredHost
import com.pntapps.plexichore.core.DisplayMode
import com.pntapps.plexichore.core.PlexiConnection
import com.pntapps.plexichore.core.Quality
import com.pntapps.plexichore.core.StreamSettings
import com.pntapps.plexichore.core.StreamStats
import com.pntapps.plexichore.ui.data.AppPreferences
import com.pntapps.plexichore.ui.data.SettingsRepository
import com.pntapps.plexichore.ui.theme.ThemeMode
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

@OptIn(ExperimentalCoroutinesApi::class)
class MainViewModel(app: Application) : AndroidViewModel(app) {
    private val repo = SettingsRepository.get(app)
    private val debuggable = (app.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0

    /** null until DataStore delivered its first value (splash stays up meanwhile). */
    val prefs: StateFlow<AppPreferences?> = repo.preferences
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    private val _connection = MutableStateFlow<PlexiConnection>(ConnectionProvider.real(app))
    val connection: StateFlow<PlexiConnection> = _connection.asStateFlow()

    val hosts: StateFlow<List<DiscoveredHost>> = _connection.flatMapLatest { it.hosts }
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    /** [hosts] with duplicates of the same computer merged into one card (USB preferred). */
    val hostGroups: StateFlow<List<HostGroup>> = hosts.map(HostGroup::merge)
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    val state: StateFlow<ConnectionState> = _connection.flatMapLatest { it.state }
        .stateIn(viewModelScope, SharingStarted.Eagerly, ConnectionState.Idle)
    val stats: StateFlow<StreamStats> = _connection.flatMapLatest { it.stats }
        .stateIn(viewModelScope, SharingStarted.Eagerly, StreamStats())

    /** Whether the user dismissed the current connection overlay (e.g. a failure). */
    private val _overlayDismissed = MutableStateFlow(false)
    val overlayDismissed: StateFlow<Boolean> = _overlayDismissed.asStateFlow()

    private var discovering = false
    private var lastHost: DiscoveredHost? = null
    private var lastManual: String? = null

    init {
        viewModelScope.launch {
            repo.preferences.map { it.demoMode && debuggable }.distinctUntilChanged().collect { demo ->
                val next = if (demo) ConnectionProvider.demo() else ConnectionProvider.real(app)
                val prev = _connection.value
                if (next !== prev) {
                    if (discovering) prev.stopDiscovery()
                    _connection.value = next
                    if (discovering) next.startDiscovery()
                }
            }
        }
    }

    private val settings: StreamSettings get() = prefs.value?.stream ?: StreamSettings()

    fun startDiscovery() { discovering = true; _connection.value.startDiscovery() }
    fun stopDiscovery() { discovering = false; _connection.value.stopDiscovery() }

    fun connect(host: DiscoveredHost) {
        lastHost = host; lastManual = null
        _overlayDismissed.value = false
        _connection.value.connect(host, settings)
    }

    fun connectManual(ip: String) {
        val trimmed = ip.trim()
        val (addr, port) = trimmed.split(":").let { it[0] to (it.getOrNull(1)?.toIntOrNull() ?: 47800) }
        lastManual = trimmed; lastHost = null
        _overlayDismissed.value = false
        viewModelScope.launch { repo.setLastManualIp(trimmed) }
        _connection.value.connectManual(addr, port, settings)
    }

    fun retry() {
        val failed = state.value as? ConnectionState.Failed
        val host = failed?.host ?: lastHost
        when {
            lastManual != null -> connectManual(lastManual!!)
            host != null -> connect(host)
        }
    }

    fun cancel() {
        _connection.value.disconnect()
        _overlayDismissed.value = true
    }

    fun disconnect() = _connection.value.disconnect()

    fun updateStream(transform: (StreamSettings) -> StreamSettings) {
        val next = transform(settings)
        viewModelScope.launch { repo.updateStream { transform(it) } }
        if (state.value is ConnectionState.Streaming) _connection.value.updateSettings(next)
    }

    fun setMode(mode: DisplayMode) = updateStream { it.copy(mode = mode) }

    fun setQuality(q: Quality) = updateStream {
        it.copy(
            quality = q,
            bitrateKbps = when (q) { Quality.PERFORMANCE -> 10_000; Quality.BALANCED -> 20_000; Quality.QUALITY -> 40_000 },
        )
    }

    fun setTheme(mode: ThemeMode) = viewModelScope.launch { repo.setThemeMode(mode) }
    fun setDynamicColor(on: Boolean) = viewModelScope.launch { repo.setDynamicColor(on) }
    fun completeOnboarding() = viewModelScope.launch { repo.setOnboardingDone(true) }
    fun resetOnboarding() = viewModelScope.launch { repo.setOnboardingDone(false) }
    fun setDemoMode(on: Boolean) = viewModelScope.launch { repo.setDemoMode(on) }
}
