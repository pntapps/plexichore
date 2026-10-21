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

/** Where the floating keyboard button sits: snapped to the left or right edge, [yFraction] of the free height. */
data class KeyboardBubblePos(val left: Boolean = false, val yFraction: Float = DEFAULT_Y) {
    companion object {
        /** Bottom-right but clear of the corner (taskbar clock / Dock) by default. */
        const val DEFAULT_Y = 0.78f
    }
}

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
        val kbButton = booleanPreferencesKey("keyboard_button")
        fun bubbleY(landscape: Boolean) = floatPreferencesKey(if (landscape) "kb_bubble_land_y" else "kb_bubble_port_y")
        fun bubbleLeft(landscape: Boolean) = booleanPreferencesKey(if (landscape) "kb_bubble_land_left" else "kb_bubble_port_left")
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
                    showKeyboardButton = p[K.kbButton] ?: d.showKeyboardButton,
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
                showKeyboardButton = p[K.kbButton] ?: true,
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
            p[K.kbButton] = s.showKeyboardButton
        }
    }

    /** Floating keyboard button position per orientation: snapped edge + vertical fraction (0 top … 1 bottom). */
    fun keyboardBubble(landscape: Boolean): Flow<KeyboardBubblePos> = store.data
        .catch { if (it is IOException) emit(emptyPreferences()) else throw it }
        .map { p ->
            KeyboardBubblePos(
                left = p[K.bubbleLeft(landscape)] ?: false,
                yFraction = (p[K.bubbleY(landscape)] ?: KeyboardBubblePos.DEFAULT_Y).coerceIn(0f, 1f),
            )
        }

    suspend fun setKeyboardBubble(landscape: Boolean, pos: KeyboardBubblePos) = store.edit {
        it[K.bubbleLeft(landscape)] = pos.left
        it[K.bubbleY(landscape)] = pos.yFraction.coerceIn(0f, 1f)
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
