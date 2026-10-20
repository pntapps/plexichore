package com.pntapps.plexichore.ui.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.pntapps.plexichore.core.DisplayMode
import com.pntapps.plexichore.core.Position
import com.pntapps.plexichore.core.Quality
import com.pntapps.plexichore.core.StreamSettings
import com.pntapps.plexichore.core.TouchMode
import com.pntapps.plexichore.ui.theme.ThemeMode
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map
import java.io.IOException

private val Context.plexiDataStore: DataStore<Preferences> by preferencesDataStore(name = "plexi_ui_settings")

/** Everything the UI persists. */
data class AppPreferences(
    val stream: StreamSettings = StreamSettings(),
    val themeMode: ThemeMode = ThemeMode.SYSTEM,
    val dynamicColor: Boolean = false,
    val onboardingDone: Boolean = false,
    val lastManualIp: String = "",
    val demoMode: Boolean = false,
)

class SettingsRepository private constructor(private val store: DataStore<Preferences>) {

    private object K {
        val mode = stringPreferencesKey("mode")
        val monitorIndex = intPreferencesKey("monitor_index")
        val scale = floatPreferencesKey("resolution_scale")
        val fps = intPreferencesKey("fps")
        val bitrate = intPreferencesKey("bitrate_kbps")
        val quality = stringPreferencesKey("quality")
        val codec = stringPreferencesKey("codec")
        val touch = stringPreferencesKey("touch_mode")
        val position = stringPreferencesKey("position")
        val keepOn = booleanPreferencesKey("keep_screen_on")
        val stats = booleanPreferencesKey("stats_overlay")
        val displayScale = intPreferencesKey("display_scale_percent")
        val theme = stringPreferencesKey("theme_mode")
        val dynamic = booleanPreferencesKey("dynamic_color")
        val onboarding = booleanPreferencesKey("onboarding_done")
        val lastIp = stringPreferencesKey("last_manual_ip")
        val demo = booleanPreferencesKey("demo_mode")
    }

    val preferences: Flow<AppPreferences> = store.data
        .catch { if (it is IOException) emit(emptyPreferences()) else throw it }
        .map { p ->
            val d = StreamSettings()
            AppPreferences(
                stream = StreamSettings(
                    mode = enumOr(p[K.mode], d.mode),
                    monitorIndex = p[K.monitorIndex] ?: d.monitorIndex,
                    resolutionScale = (p[K.scale] ?: d.resolutionScale).coerceIn(0.5f, 1f),
                    fps = p[K.fps] ?: d.fps,
                    bitrateKbps = p[K.bitrate] ?: d.bitrateKbps,
                    quality = enumOr(p[K.quality], d.quality),
                    codec = p[K.codec] ?: d.codec,
                    touchMode = enumOr(p[K.touch], d.touchMode),
                    position = enumOr(p[K.position], d.position),
                    keepScreenOn = p[K.keepOn] ?: d.keepScreenOn,
                    showStatsOverlay = p[K.stats] ?: d.showStatsOverlay,
                    scalePercent = p[K.displayScale] ?: d.scalePercent,
                ),
                themeMode = enumOr(p[K.theme], ThemeMode.SYSTEM),
                dynamicColor = p[K.dynamic] ?: false,
                onboardingDone = p[K.onboarding] ?: false,
                lastManualIp = p[K.lastIp] ?: "",
                demoMode = p[K.demo] ?: false,
            )
        }

    suspend fun updateStream(transform: (StreamSettings) -> StreamSettings) {
        store.edit { p ->
            val current = StreamSettings(
                mode = enumOr(p[K.mode], DisplayMode.EXTEND),
                monitorIndex = p[K.monitorIndex] ?: 0,
                resolutionScale = p[K.scale] ?: 1f,
                fps = p[K.fps] ?: 60,
                bitrateKbps = p[K.bitrate] ?: 20_000,
                quality = enumOr(p[K.quality], Quality.BALANCED),
                codec = p[K.codec] ?: "h264",
                touchMode = enumOr(p[K.touch], TouchMode.TOUCH),
                position = enumOr(p[K.position], Position.RIGHT),
                keepScreenOn = p[K.keepOn] ?: true,
                showStatsOverlay = p[K.stats] ?: false,
                scalePercent = p[K.displayScale] ?: 0,
            )
            val s = transform(current)
            p[K.mode] = s.mode.name
            p[K.monitorIndex] = s.monitorIndex
            p[K.scale] = s.resolutionScale
            p[K.fps] = s.fps
            p[K.bitrate] = s.bitrateKbps
            p[K.quality] = s.quality.name
            p[K.codec] = s.codec
            p[K.touch] = s.touchMode.name
            p[K.position] = s.position.name
            p[K.keepOn] = s.keepScreenOn
            p[K.stats] = s.showStatsOverlay
            p[K.displayScale] = s.scalePercent
        }
    }

    suspend fun setThemeMode(mode: ThemeMode) = store.edit { it[K.theme] = mode.name }
    suspend fun setDynamicColor(on: Boolean) = store.edit { it[K.dynamic] = on }
    suspend fun setOnboardingDone(done: Boolean) = store.edit { it[K.onboarding] = done }
    suspend fun setLastManualIp(ip: String) = store.edit { it[K.lastIp] = ip }
    suspend fun setDemoMode(on: Boolean) = store.edit { it[K.demo] = on }

    companion object {
        @Volatile private var instance: SettingsRepository? = null
        fun get(context: Context): SettingsRepository = instance ?: synchronized(this) {
            instance ?: SettingsRepository(context.applicationContext.plexiDataStore).also { instance = it }
        }

        private inline fun <reified E : Enum<E>> enumOr(name: String?, default: E): E =
            name?.let { n -> enumValues<E>().firstOrNull { it.name == n } } ?: default
    }
}
