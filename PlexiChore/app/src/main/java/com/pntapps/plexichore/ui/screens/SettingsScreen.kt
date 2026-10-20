package com.pntapps.plexichore.ui.screens

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Build
import android.view.WindowManager
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import com.pntapps.plexichore.ui.components.plexiSafeTopAndSides
import com.pntapps.plexichore.ui.components.safeBottomPadding
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.DarkMode
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.automirrored.rounded.HelpOutline
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.LightMode
import androidx.compose.material.icons.rounded.LightbulbCircle
import androidx.compose.material.icons.rounded.Mouse
import androidx.compose.material.icons.rounded.Palette
import androidx.compose.material.icons.rounded.QueryStats
import androidx.compose.material.icons.rounded.ScreenShare
import androidx.compose.material.icons.rounded.Science
import androidx.compose.material.icons.rounded.SettingsBrightness
import androidx.compose.material.icons.rounded.TouchApp
import androidx.compose.material.icons.rounded.DoNotTouch
import androidx.compose.material.icons.automirrored.rounded.ViewQuilt
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.Balance
import androidx.compose.material.icons.rounded.Diamond
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pntapps.plexichore.R
import com.pntapps.plexichore.core.DisplayMode
import com.pntapps.plexichore.core.Quality
import com.pntapps.plexichore.core.StreamSettings
import com.pntapps.plexichore.core.TouchMode
import com.pntapps.plexichore.ui.MainViewModel
import com.pntapps.plexichore.ui.components.ChoiceChips
import com.pntapps.plexichore.ui.components.DisplayScaleUi
import com.pntapps.plexichore.ui.components.GhostButton
import com.pntapps.plexichore.ui.components.GlassCard
import com.pntapps.plexichore.ui.components.GlassIconButton
import com.pntapps.plexichore.ui.components.GradientText
import com.pntapps.plexichore.ui.components.Hairline
import com.pntapps.plexichore.ui.components.IconBadge
import com.pntapps.plexichore.ui.components.PlexiSwitch
import com.pntapps.plexichore.ui.components.PositionPicker
import com.pntapps.plexichore.ui.components.SectionLabel
import com.pntapps.plexichore.ui.components.SegmentOption
import com.pntapps.plexichore.ui.components.SegmentedControl
import com.pntapps.plexichore.ui.components.SettingRow
import com.pntapps.plexichore.ui.components.displayModeOptions
import com.pntapps.plexichore.ui.components.description
import com.pntapps.plexichore.ui.components.usesPosition
import com.pntapps.plexichore.ui.navigation.LocalAdaptive
import com.pntapps.plexichore.ui.theme.Plexi
import com.pntapps.plexichore.ui.theme.ThemeMode
import kotlin.math.roundToInt

@Composable
fun SettingsScreen(vm: MainViewModel, onBack: () -> Unit, onOpenHelp: () -> Unit) {
    val prefs by vm.prefs.collectAsStateWithLifecycle()
    val p = prefs ?: return
    val s = p.stream
    val twoPane = LocalAdaptive.current.twoPane
    val update = vm::updateStream

    Column(Modifier.fillMaxSize().plexiSafeTopAndSides()) {
        ScreenHeader("Settings", "Tune how your tablet behaves as a display", onBack)
        val scroll = rememberScrollState()
        val bottom = safeBottomPadding() + 28.dp
        if (twoPane) {
            Row(
                Modifier.fillMaxSize().verticalScroll(scroll).padding(start = 28.dp, end = 28.dp, bottom = bottom),
                horizontalArrangement = Arrangement.spacedBy(24.dp),
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                    DisplayCard(s, update, vm)
                    InputCard(s, update)
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                    StreamCard(s, update, vm)
                    BehaviourCard(s, update)
                    AppearanceCard(p.themeMode, p.dynamicColor, vm)
                    AboutCard(p.demoMode, vm, onOpenHelp)
                }
            }
        } else {
            Column(
                Modifier.fillMaxSize().verticalScroll(scroll).padding(start = 24.dp, end = 24.dp, bottom = bottom),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                DisplayCard(s, update, vm)
                StreamCard(s, update, vm)
                InputCard(s, update)
                BehaviourCard(s, update)
                AppearanceCard(p.themeMode, p.dynamicColor, vm)
                AboutCard(p.demoMode, vm, onOpenHelp)
            }
        }
    }
}

@Composable
fun ScreenHeader(title: String, subtitle: String, onBack: () -> Unit) {
    val c = Plexi.colors
    Row(Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, top = 14.dp, bottom = 18.dp), verticalAlignment = Alignment.CenterVertically) {
        GlassIconButton(Icons.AutoMirrored.Rounded.ArrowBack, "Back", onBack)
        Spacer(Modifier.width(16.dp))
        Column {
            Text(title, style = MaterialTheme.typography.headlineMedium, color = c.textPrimary)
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = c.textSecondary)
        }
    }
}

@Composable
private fun SettingsCard(title: String, icon: ImageVector, content: @Composable ColumnScope.() -> Unit) {
    val c = Plexi.colors
    GlassCard(Modifier.fillMaxWidth(), contentPadding = PaddingValues(24.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconBadge(icon, size = 36.dp)
            Spacer(Modifier.width(12.dp))
            Text(title, style = MaterialTheme.typography.titleLarge, color = c.textPrimary)
        }
        Spacer(Modifier.height(20.dp))
        content()
    }
}

@Composable
private fun ValueHeader(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        SectionLabel(label, Modifier.weight(1f))
        GradientText(value, MaterialTheme.typography.titleMedium)
    }
}

@Composable
private fun PlexiSlider(value: Float, onChange: (Float) -> Unit, range: ClosedFloatingPointRange<Float>, steps: Int, onDone: () -> Unit = {}) {
    val c = Plexi.colors
    val haptic = LocalHapticFeedback.current
    var last by remember { mutableFloatStateOf(value) }
    Slider(
        value = value,
        onValueChange = {
            if (steps > 0 && it != last) haptic.performHapticFeedback(HapticFeedbackType.SegmentFrequentTick)
            last = it
            onChange(it)
        },
        onValueChangeFinished = onDone,
        valueRange = range,
        steps = steps,
        colors = SliderDefaults.colors(
            thumbColor = c.accentEnd,
            activeTrackColor = c.accentStart,
            inactiveTrackColor = c.glassBorderHighlight.copy(alpha = 0.18f),
            activeTickColor = Color0,
            inactiveTickColor = Color0,
        ),
    )
}

private val Color0 = androidx.compose.ui.graphics.Color.Transparent

/* ---------------------------------------------------------------- Display */

private fun nativeLandscapeSize(ctx: Context): Pair<Int, Int> {
    val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    val (w, h) = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        wm.maximumWindowMetrics.bounds.let { it.width() to it.height() }
    } else {
        val m = android.util.DisplayMetrics()
        @Suppress("DEPRECATION") wm.defaultDisplay.getRealMetrics(m)
        m.widthPixels to m.heightPixels
    }
    return maxOf(w, h) to minOf(w, h)
}

@Composable
private fun DisplayCard(s: StreamSettings, update: ((StreamSettings) -> StreamSettings) -> Unit, vm: MainViewModel) {
    val c = Plexi.colors
    val ctx = LocalContext.current
    val native = remember { nativeLandscapeSize(ctx) }
    var scale by remember(s.resolutionScale) { mutableFloatStateOf(s.resolutionScale) }
    SettingsCard("Display", Icons.AutoMirrored.Rounded.ViewQuilt) {
        SectionLabel("Mode")
        Spacer(Modifier.height(10.dp))
        SegmentedControl(
            displayModeOptions,
            s.mode, vm::setMode, Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(8.dp))
        Text(s.mode.description, style = MaterialTheme.typography.bodySmall, color = c.textTertiary)
        AnimatedVisibility(s.mode.usesPosition) {
            Column {
                Spacer(Modifier.height(22.dp))
                SectionLabel("Tablet position")
                Spacer(Modifier.height(4.dp))
                Text("Tap a slot or drag the tablet to match your desk.", style = MaterialTheme.typography.bodySmall, color = c.textTertiary)
                Spacer(Modifier.height(12.dp))
                PositionPicker(s.position, { pos -> update { it.copy(position = pos) } }, monitorLabel = if (s.mode == DisplayMode.PRIMARY) "Your monitor" else "Main display")
            }
        }
        AnimatedVisibility(s.mode.usesPosition) {
            Column {
                Spacer(Modifier.height(22.dp))
                val density = ctx.resources.displayMetrics.densityDpi
                val shown = if (s.scalePercent <= 0) DisplayScaleUi.autoPercent(density, s.resolutionScale) else s.scalePercent
                ValueHeader("Display size", DisplayScaleUi.label(s.scalePercent) + if (s.scalePercent <= 0) " · $shown%" else "")
                Spacer(Modifier.height(10.dp))
                val opts = DisplayScaleUi.options
                ChoiceChips(
                    opts.map(DisplayScaleUi::label),
                    opts.indexOf(s.scalePercent).coerceAtLeast(0),
                    { i -> update { it.copy(scalePercent = opts[i]) } },
                    Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    DisplayScaleUi.preview(s.scalePercent, density, s.resolutionScale) + ". Sets your computer's display scale for the tablet screen only.",
                    style = MaterialTheme.typography.bodySmall, color = c.textTertiary,
                )
            }
        }
        Spacer(Modifier.height(22.dp))
        val w = ((native.first * scale).roundToInt() / 2) * 2
        val h = ((native.second * scale).roundToInt() / 2) * 2
        ValueHeader("Resolution", "$w × $h")
        PlexiSlider(scale, { scale = (it * 20).roundToInt() / 20f }, 0.5f..1f, steps = 9, onDone = { update { it.copy(resolutionScale = scale) } })
        Row {
            Text("${(scale * 100).roundToInt()}% of native", style = MaterialTheme.typography.bodySmall, color = c.textTertiary, modifier = Modifier.weight(1f))
            Text("Native ${native.first} × ${native.second}", style = MaterialTheme.typography.bodySmall, color = c.textTertiary)
        }
        Spacer(Modifier.height(22.dp))
        SectionLabel("Frame rate")
        Spacer(Modifier.height(10.dp))
        val fpsOptions = listOf(30, 60, 90, 120)
        ChoiceChips(fpsOptions.map { "$it fps" }, fpsOptions.indexOf(s.fps).coerceAtLeast(0), { i -> update { it.copy(fps = fpsOptions[i]) } }, Modifier.fillMaxWidth())
    }
}

/* ---------------------------------------------------------------- Streaming */

@Composable
private fun StreamCard(s: StreamSettings, update: ((StreamSettings) -> StreamSettings) -> Unit, vm: MainViewModel) {
    val c = Plexi.colors
    var bitrate by remember(s.bitrateKbps) { mutableFloatStateOf(s.bitrateKbps / 1000f) }
    SettingsCard("Streaming", Icons.Rounded.AutoAwesome) {
        SectionLabel("Quality preset")
        Spacer(Modifier.height(10.dp))
        SegmentedControl(
            listOf(
                SegmentOption(Quality.PERFORMANCE, "Speed", Icons.Rounded.Bolt),
                SegmentOption(Quality.BALANCED, "Balanced", Icons.Rounded.Balance),
                SegmentOption(Quality.QUALITY, "Quality", Icons.Rounded.Diamond),
            ),
            s.quality, vm::setQuality, Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(22.dp))
        ValueHeader("Bitrate", "${bitrate.roundToInt()} Mbps")
        PlexiSlider(bitrate, { bitrate = it.roundToInt().toFloat() }, 2f..80f, steps = 0, onDone = { update { it.copy(bitrateKbps = bitrate.roundToInt() * 1000) } })
        Text(
            when {
                bitrate < 8 -> "Lighter on Wi-Fi, softer text."
                bitrate < 30 -> "Great balance for most networks."
                else -> "Crisp text — best over USB or Wi-Fi 6."
            },
            style = MaterialTheme.typography.bodySmall, color = c.textTertiary,
        )
        Spacer(Modifier.height(22.dp))
        SectionLabel("Codec")
        Spacer(Modifier.height(10.dp))
        SegmentedControl(
            listOf(SegmentOption("h264", "H.264"), SegmentOption("mjpeg", "MJPEG")),
            s.codec, { codec -> update { it.copy(codec = codec) } }, Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(8.dp))
        Text(
            if (s.codec == "h264") "Hardware-accelerated. Lowest bandwidth and latency." else "Compatibility fallback. Uses much more bandwidth.",
            style = MaterialTheme.typography.bodySmall, color = c.textTertiary,
        )
    }
}

/* ---------------------------------------------------------------- Input */

@Composable
private fun InputCard(s: StreamSettings, update: ((StreamSettings) -> StreamSettings) -> Unit) {
    val c = Plexi.colors
    SettingsCard("Touch & pen", Icons.Rounded.TouchApp) {
        SectionLabel("Touch input")
        Spacer(Modifier.height(10.dp))
        SegmentedControl(
            listOf(
                SegmentOption(TouchMode.TOUCH, "Touch", Icons.Rounded.TouchApp),
                SegmentOption(TouchMode.MOUSE, "Mouse", Icons.Rounded.Mouse),
                SegmentOption(TouchMode.NONE, "Off", Icons.Rounded.DoNotTouch),
            ),
            s.touchMode, { m -> update { it.copy(touchMode = m) } }, Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(8.dp))
        Text(
            when (s.touchMode) {
                TouchMode.TOUCH -> "Multi-touch gestures are sent to your computer. Pen pressure and tilt included."
                TouchMode.MOUSE -> "Your finger moves the cursor and taps click, like a mouse."
                TouchMode.NONE -> "The tablet is display-only; touches are ignored."
            },
            style = MaterialTheme.typography.bodySmall, color = c.textTertiary,
        )
    }
}

/* ---------------------------------------------------------------- Behaviour */

@Composable
private fun BehaviourCard(s: StreamSettings, update: ((StreamSettings) -> StreamSettings) -> Unit) {
    SettingsCard("While streaming", Icons.Rounded.LightbulbCircle) {
        SettingRow("Keep screen on", "Prevent the tablet from sleeping while connected") {
            PlexiSwitch(s.keepScreenOn) { v -> update { it.copy(keepScreenOn = v) } }
        }
        Spacer(Modifier.height(16.dp)); Hairline(); Spacer(Modifier.height(16.dp))
        SettingRow("Stats overlay", "Show FPS, latency and bitrate on the display") {
            PlexiSwitch(s.showStatsOverlay) { v -> update { it.copy(showStatsOverlay = v) } }
        }
    }
}

/* ---------------------------------------------------------------- Appearance */

@Composable
private fun AppearanceCard(theme: ThemeMode, dynamic: Boolean, vm: MainViewModel) {
    SettingsCard("Appearance", Icons.Rounded.Palette) {
        SectionLabel("Theme")
        Spacer(Modifier.height(10.dp))
        SegmentedControl(
            listOf(
                SegmentOption(ThemeMode.SYSTEM, "System", Icons.Rounded.SettingsBrightness),
                SegmentOption(ThemeMode.DARK, "Dark", Icons.Rounded.DarkMode),
                SegmentOption(ThemeMode.LIGHT, "Light", Icons.Rounded.LightMode),
            ),
            theme, { vm.setTheme(it) }, Modifier.fillMaxWidth(),
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Spacer(Modifier.height(18.dp))
            SettingRow("Dynamic color", "Tint PlexiChore with your wallpaper colors") {
                PlexiSwitch(dynamic) { vm.setDynamicColor(it) }
            }
        }
    }
}

/* ---------------------------------------------------------------- About */

@Composable
private fun AboutCard(demo: Boolean, vm: MainViewModel, onOpenHelp: () -> Unit) {
    val c = Plexi.colors
    val ctx = LocalContext.current
    val version = remember {
        runCatching { ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName }.getOrNull() ?: "—"
    }
    val debuggable = remember { (ctx.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0 }
    SettingsCard("About", Icons.Rounded.Info) {
        SettingRow("PlexiChore", "Version $version · Protocol v1")
        Spacer(Modifier.height(16.dp)); Hairline(); Spacer(Modifier.height(16.dp))
        SettingRow("PlexiChore Desktop", "Install on your Windows PC or Mac:\n" + stringResource(R.string.desktop_app_url), icon = Icons.Rounded.Download)
        Spacer(Modifier.height(16.dp))
        @OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
        androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            GhostButton("Setup guide", onOpenHelp, icon = Icons.AutoMirrored.Rounded.HelpOutline, height = 48.dp)
            GhostButton("Replay intro", { vm.resetOnboarding() }, icon = Icons.Rounded.AutoAwesome, height = 48.dp)
        }
        if (debuggable) {
            Spacer(Modifier.height(16.dp)); Hairline(); Spacer(Modifier.height(16.dp))
            SettingRow("Demo mode", "Simulated computers for testing the UI", icon = Icons.Rounded.Science) {
                PlexiSwitch(demo) { vm.setDemoMode(it) }
            }
        }
    }
}
