package com.pntapps.plexichore.screenshots

import android.app.Application
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.compose.runtime.Recomposer
import androidx.compose.ui.platform.AndroidUiDispatcher
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.InfiniteAnimationPolicy
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.windowsizeclass.ExperimentalMaterial3WindowSizeClassApi
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.drawToBitmap
import com.github.takahirom.roborazzi.RoborazziOptions
import com.github.takahirom.roborazzi.captureRoboImage
import com.pntapps.plexichore.core.ConnectionState
import com.pntapps.plexichore.core.DiscoveredHost
import com.pntapps.plexichore.core.DisplayMode
import com.pntapps.plexichore.core.PlexiConnection
import com.pntapps.plexichore.core.StreamConfig
import com.pntapps.plexichore.core.StreamSettings
import com.pntapps.plexichore.core.StreamStats
import com.pntapps.plexichore.core.Transport
import com.pntapps.plexichore.display.DisplayOverlay
import com.pntapps.plexichore.ui.MainViewModel
import com.pntapps.plexichore.ui.components.AuroraBackground
import com.pntapps.plexichore.ui.navigation.adaptiveInfo
import com.pntapps.plexichore.ui.navigation.LocalAdaptive
import com.pntapps.plexichore.ui.screens.ConnectionOverlay
import com.pntapps.plexichore.ui.screens.HelpScreen
import com.pntapps.plexichore.ui.screens.HomeScreen
import com.pntapps.plexichore.ui.screens.OnboardingScreen
import com.pntapps.plexichore.ui.screens.SettingsScreen
import com.pntapps.plexichore.ui.theme.PlexiChoreTheme
import com.pntapps.plexichore.ui.theme.ThemeMode
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.Robolectric
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.time.Duration
import kotlin.math.roundToInt

/**
 * Renders the real Compose screens across a tablet/phone/foldable matrix on the JVM
 * (Robolectric native graphics + Roborazzi), with simulated system-bar/taskbar insets drawn as
 * translucent red bands so overlap with content is visible.
 *
 * Run:  ./gradlew :app:testDebugUnitTest --tests "*DeviceMatrixScreenshotTest*"
 * Output: app/build/outputs/roborazzi/<config>/<scene>.png
 * Filter configs: -Pplexi.shots=tab7_land,phone_port (see [configs]); default = all.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class DeviceMatrixScreenshotTest(private val cfg: ShotConfig) {

    data class ShotConfig(
        val name: String,
        val qualifiers: String,
        val fontScale: Float = 1f,
        val dark: Boolean = true,
        /** Simulated insets in dp: status bar top, navigation bar / taskbar bottom. */
        val statusDp: Int = 24,
        val navDp: Int = 48,
    ) {
        override fun toString() = name
    }

    companion object {
        private val base = listOf(
            ShotConfig("phone_port", "w411dp-h914dp-port-420dpi", navDp = 24),
            ShotConfig("phone_land", "w914dp-h411dp-land-420dpi", navDp = 24),
            ShotConfig("tab7_port", "w600dp-h1024dp-port-mdpi"),
            ShotConfig("tab7_land", "w1024dp-h600dp-land-mdpi"),
            ShotConfig("tab8_port", "w601dp-h961dp-port-tvdpi"),
            ShotConfig("tab10_port", "w800dp-h1280dp-port-hdpi"),
            ShotConfig("tabS8_land", "w1280dp-h800dp-land-xhdpi", navDp = 56),
            ShotConfig("tabS8_port", "w800dp-h1280dp-port-xhdpi", navDp = 56),
            ShotConfig("tab12_land", "w1400dp-h876dp-land-xhdpi", navDp = 56),
            ShotConfig("ultra_land", "w1480dp-h924dp-land-xhdpi", navDp = 56),
            ShotConfig("r43_land", "w1024dp-h768dp-land-xhdpi"),
            ShotConfig("r43_port", "w768dp-h1024dp-port-xhdpi"),
            ShotConfig("r32_land", "w1440dp-h960dp-land-xhdpi"),
            ShotConfig("fold_inner", "w829dp-h690dp-land-420dpi"),
        )
        private val extra = listOf(
            ShotConfig("tab7_land_fs130", "w1024dp-h600dp-land-mdpi", fontScale = 1.3f),
            ShotConfig("tabS8_land_fs130", "w1280dp-h800dp-land-xhdpi", fontScale = 1.3f, navDp = 56),
            ShotConfig("phone_port_fs130", "w411dp-h914dp-port-420dpi", fontScale = 1.3f, navDp = 24),
            ShotConfig("tab7_port_fs200", "w600dp-h1024dp-port-mdpi", fontScale = 2f),
            ShotConfig("tab7_land_fs200", "w1024dp-h600dp-land-mdpi", fontScale = 2f),
            ShotConfig("tabS8_land_fs200", "w1280dp-h800dp-land-xhdpi", fontScale = 2f, navDp = 56),
            ShotConfig("phone_port_fs200", "w411dp-h914dp-port-420dpi", fontScale = 2f, navDp = 24),
            ShotConfig("fold_inner_fs200", "w829dp-h690dp-land-420dpi", fontScale = 2f),
            ShotConfig("tabS8_land_light", "w1280dp-h800dp-land-xhdpi", dark = false, navDp = 56),
            ShotConfig("tab7_port_light", "w600dp-h1024dp-port-mdpi", dark = false),
            ShotConfig("phone_port_light", "w411dp-h914dp-port-420dpi", dark = false, navDp = 24),
            ShotConfig("tabS8_land_rtl", "ar-ldrtl-w1280dp-h800dp-land-xhdpi", navDp = 56),
        )

        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}")
        fun configs(): List<Array<Any>> {
            val filter = System.getProperty("plexi.shots")?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() }
            return (base + extra)
                .filter { filter.isNullOrEmpty() || it.name in filter }
                .map { arrayOf<Any>(it) }
        }

        private val wifiHost = DiscoveredHost("mbp", "Studio MacBook Pro", "macos", "192.168.1.24", 47800, Transport.WIFI, true, 0)
        private val usbHost = DiscoveredHost("usb", "DESIGN-WORKSTATION", "windows", "127.0.0.1", 47800, Transport.USB, true, 0)
        private val longHost = DiscoveredHost(
            "long", "An extremely long Windows workstation name (Design Studio, Floor 3)", "windows",
            "192.168.100.254", 47800, Transport.WIFI, false, 0,
        )
        private val manyHosts = listOf(
            usbHost, wifiHost,
            DiscoveredHost("imac", "Studio-iMac", "macos", "192.168.1.40", 47800, Transport.WIFI, false, 0),
            longHost,
            DiscoveredHost("lab", "LAB-PC-07", "windows", "10.0.0.7", 47800, Transport.MANUAL, true, 0),
        )
        private val mergedHosts = listOf(
            usbHost,
            DiscoveredHost("ws-guid", "DESIGN-WORKSTATION", "windows", "192.168.1.10", 47800, Transport.WIFI, true, 0),
            wifiHost,
        )
        private val streamingConfig = StreamConfig("h264", 2560, 1600, 60, 20000, DisplayMode.EXTEND, longHost.name, "windows", true)
    }

    /** Fully controlled stand-in for the core (no sockets, no timers). */
    private class TestConnection(hosts: List<DiscoveredHost>, state: ConnectionState) : PlexiConnection {
        override val state: StateFlow<ConnectionState> = MutableStateFlow(state)
        override val hosts: StateFlow<List<DiscoveredHost>> = MutableStateFlow(hosts)
        override val stats: StateFlow<StreamStats> = MutableStateFlow(StreamStats(59.8f, 6.2f, 18_400, 3.1f, 2))
        override fun startDiscovery() = Unit
        override fun stopDiscovery() = Unit
        override fun connect(host: DiscoveredHost, settings: StreamSettings) = Unit
        override fun connectManual(ip: String, port: Int, settings: StreamSettings) = Unit
        override fun updateSettings(settings: StreamSettings) = Unit
        override fun disconnect() = Unit
    }

    private val outDir get() = "build/outputs/roborazzi/${cfg.name}"

    @Test
    fun matrix() {
        RuntimeEnvironment.setQualifiers(cfg.qualifiers.replace(Regex("-(land|port)-"), "-$1-" + (if (cfg.dark) "night" else "notnight") + "-"))
        RuntimeEnvironment.setFontScale(cfg.fontScale)

        shot("01_onboarding") { _, _ -> OnboardingScreen(onFinish = {}) }
        shot("02_home_empty", conn = TestConnection(emptyList(), ConnectionState.Idle)) { vm, _ -> home(vm!!) }
        shot("03_home_one", conn = TestConnection(listOf(wifiHost), ConnectionState.Idle)) { vm, _ -> home(vm!!) }
        shot("04_home_many_streaming", conn = TestConnection(manyHosts, ConnectionState.Streaming(longHost, streamingConfig))) { vm, _ -> home(vm!!) }
        shot("05_home_many_bottom", conn = TestConnection(manyHosts, ConnectionState.Idle), scrolls = 6) { vm, _ -> home(vm!!) }
        shot("06_home_long_names", conn = TestConnection(listOf(longHost, wifiHost), ConnectionState.Idle)) { vm, _ -> home(vm!!) }
        shot("07_overlay_connecting", conn = TestConnection(listOf(longHost), ConnectionState.Connecting(longHost))) { vm, _ -> home(vm!!) }
        shot("08_overlay_pairing", conn = TestConnection(listOf(wifiHost), ConnectionState.AwaitingApproval(longHost, "4821"))) { vm, _ -> home(vm!!) }
        shot(
            "09_overlay_failed",
            conn = TestConnection(
                listOf(wifiHost),
                ConnectionState.Failed(longHost, "${longHost.name} refused the connection. Is PlexiChore running on the computer? Allow it through the firewall on private networks."),
            ),
        ) { vm, _ -> home(vm!!) }
        shot("10_settings_top", conn = TestConnection(emptyList(), ConnectionState.Idle)) { vm, _ -> SettingsScreen(vm!!, onBack = {}, onOpenHelp = {}) }
        shot("11_settings_bottom", conn = TestConnection(emptyList(), ConnectionState.Idle), scrolls = 8) { vm, _ -> SettingsScreen(vm!!, onBack = {}, onOpenHelp = {}) }
        shot("12_help") { _, _ -> HelpScreen(onBack = {}) }
        shot("13_help_bottom", scrolls = 8) { _, _ -> HelpScreen(onBack = {}) }
        shot("14_display_pill", appFrame = false) { _, _ ->
            Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color(0xFF203040))) {
                DisplayOverlay(
                    state = ConnectionState.Streaming(longHost, streamingConfig),
                    stats = StreamStats(59.8f, 6.2f, 18_400, 3.1f, 2),
                    settings = StreamSettings(showStatsOverlay = true),
                    controlsVisible = true, showHint = false, hasStreamed = true,
                    onDisconnect = {}, onToggleStats = {}, onCycleTouchMode = {}, onRegion = { _, _ -> },
                )
            }
        }
        shot("15_display_pairing", appFrame = false) { _, _ ->
            Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black)) {
                DisplayOverlay(
                    state = ConnectionState.AwaitingApproval(longHost, "4821"),
                    stats = StreamStats(), settings = StreamSettings(),
                    controlsVisible = false, showHint = false, hasStreamed = false,
                    onDisconnect = {}, onToggleStats = {}, onCycleTouchMode = {}, onRegion = { _, _ -> },
                )
            }
        }
        shot("16_display_hint", appFrame = false) { _, _ ->
            Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color(0xFF203040))) {
                DisplayOverlay(
                    state = ConnectionState.Streaming(longHost, streamingConfig),
                    stats = StreamStats(), settings = StreamSettings(),
                    controlsVisible = false, showHint = true, hasStreamed = true,
                    onDisconnect = {}, onToggleStats = {}, onCycleTouchMode = {}, onRegion = { _, _ -> },
                )
            }
        }
        // Same computer seen over USB *and* Wi-Fi (+ one other): must render as 2 cards.
        shot("17_home_merged_hosts", conn = TestConnection(mergedHosts, ConnectionState.Idle)) { vm, _ -> home(vm!!) }
        shot("18_onboarding_last", swipesLeft = 2) { _, _ -> OnboardingScreen(onFinish = {}) }
        // Hero illustration per display mode (Extend is what 03_home_one shows).
        shot("19_home_mode_primary", conn = TestConnection(listOf(wifiHost), ConnectionState.Idle), mode = DisplayMode.PRIMARY) { vm, _ -> home(vm!!) }
        shot("20_home_mode_mirror", conn = TestConnection(listOf(wifiHost), ConnectionState.Idle), mode = DisplayMode.MIRROR) { vm, _ -> home(vm!!) }
    }

    /** API 37 only: Local Network Protection UI (Home card + onboarding button). */
    fun api37Scenes() {
        RuntimeEnvironment.setQualifiers(cfg.qualifiers.replace(Regex("-(land|port)-"), "-$1-night-"))
        RuntimeEnvironment.setFontScale(cfg.fontScale)
        shot("api37_home_lan_card", conn = TestConnection(listOf(usbHost), ConnectionState.Idle)) { vm, _ -> home(vm!!) }
        shot("api37_onboarding_last", swipesLeft = 2) { _, _ -> OnboardingScreen(onFinish = {}) }
    }

    @Composable
    private fun home(vm: MainViewModel) {
        // Same stacking as MainNav: screen + full-screen connection overlay.
        Box(Modifier.fillMaxSize()) {
            HomeScreen(vm, onOpenSettings = {}, onOpenHelp = {})
            ConnectionOverlay(vm, onOpenHelp = {})
        }
    }

    @OptIn(ExperimentalMaterial3WindowSizeClassApi::class)
    private fun shot(
        scene: String,
        conn: PlexiConnection? = null,
        scrolls: Int = 0,
        swipesLeft: Int = 0,
        appFrame: Boolean = true,
        /** Display mode selected before the scene renders (restored to Extend afterwards). */
        mode: DisplayMode? = null,
        content: @Composable (MainViewModel?, ComponentActivity) -> Unit,
    ) {
        log("$scene start")
        val app = RuntimeEnvironment.getApplication()
        val vm = conn?.let { makeVm(app, it) }
        if (vm != null && mode != null) { vm.setMode(mode); waitFor { vm.prefs.value?.stream?.mode == mode } }
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        val activity = controller.get()
        // Like compose-ui-test: infinite animations (aurora, radar, pulsing dots) are cancelled,
        // otherwise every idled frame is re-rendered natively and a scene takes minutes.
        val uiContext = AndroidUiDispatcher.CurrentThread + NoInfiniteAnimations
        val recomposer = Recomposer(uiContext)
        val recomposeJob = CoroutineScope(uiContext).launch { recomposer.runRecomposeAndApplyChanges() }
        try {
            activity.enableEdgeToEdge()
            val composeView = ComposeView(activity).apply { setParentCompositionContext(recomposer) }
            activity.setContentView(composeView)
            composeView.setContent {
                PlexiChoreTheme(themeMode = if (cfg.dark) ThemeMode.DARK else ThemeMode.LIGHT) {
                    if (appFrame) {
                        // Mirrors PlexiApp's adaptive computation.
                        val config = LocalConfiguration.current
                        CompositionLocalProvider(LocalAdaptive provides adaptiveInfo(config.screenWidthDp, config.screenHeightDp, config.fontScale)) {
                            AuroraBackground(Modifier.fillMaxSize()) { content(vm, activity) }
                        }
                    } else content(vm, activity)
                }
            }
            val root = activity.findViewById<ViewGroup>(android.R.id.content)
            val compose = root.getChildAt(0)
            log("$scene content set"); idle(600)
            applyInsets(compose, activity.resources.displayMetrics.density)
            addInsetBands(activity, root)
            idle(1200)
            if (vm != null) check(vm.connection.value === conn) { "fake connection was replaced" }
            repeat(scrolls) {
                swipeUp(compose)
                idle(500)
            }
            repeat(swipesLeft) {
                swipeLeft(compose)
                idle(900)
            }
            idle(800)
            val maxPx = maxOf(root.width, root.height).coerceAtLeast(1)
            val scale = (1400.0 / maxPx).coerceAtMost(1.0)
            val options = RoborazziOptions(recordOptions = RoborazziOptions.RecordOptions(resizeScale = scale))
            if (android.os.Build.VERSION.SDK_INT >= 37) {
                // Espresso (used by View.captureRoboImage) cannot initialise on the API 37 sandbox.
                activity.window.decorView.drawToBitmap().captureRoboImage("$outDir/$scene.png", options)
            } else {
                activity.window.decorView.captureRoboImage("$outDir/$scene.png", options)
            }
            log("$scene captured")
        } finally {
            if (vm != null && mode != null) { vm.setMode(DisplayMode.EXTEND); waitFor { vm.prefs.value?.stream?.mode == DisplayMode.EXTEND } }
            controller.pause().stop().destroy()
            recomposer.cancel()
            recomposeJob.cancel()
            idle(50)
        }
    }

    private fun makeVm(app: Application, conn: PlexiConnection): MainViewModel {
        val vm = MainViewModel(app); log("vm created")
        // Wait for DataStore + the VM's demo-mode collector, then swap in the controlled fake.
        val deadline = System.currentTimeMillis() + 10_000
        while (vm.prefs.value == null && System.currentTimeMillis() < deadline) {
            idle(50)
            Thread.sleep(20)
        }
        log("prefs ready=${vm.prefs.value != null}"); repeat(5) { idle(50); Thread.sleep(20) }
        val field = MainViewModel::class.java.getDeclaredField("_connection").apply { isAccessible = true }
        @Suppress("UNCHECKED_CAST")
        (field.get(vm) as MutableStateFlow<PlexiConnection>).value = conn
        idle(100)
        return vm
    }

    private fun waitFor(cond: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (!cond() && System.currentTimeMillis() < deadline) {
            idle(50)
            Thread.sleep(20)
        }
    }

    private fun idle(ms: Long) {
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))
    }

    private fun applyInsets(view: View, density: Float) {
        val top = (cfg.statusDp * density).roundToInt()
        val bottom = (cfg.navDp * density).roundToInt()
        // Tablets: model the One UI / 12L taskbar, which is a tappable element while
        // navigationBars is only the small gesture handle. Phones: a plain gesture nav bar.
        val navBottom = if (cfg.navDp >= 48) (16 * density).roundToInt() else bottom
        val insets = WindowInsetsCompat.Builder()
            .setInsets(WindowInsetsCompat.Type.statusBars(), Insets.of(0, top, 0, 0))
            .setInsets(WindowInsetsCompat.Type.navigationBars(), Insets.of(0, 0, 0, navBottom))
            .setInsets(WindowInsetsCompat.Type.tappableElement(), Insets.of(0, top, 0, bottom))
            .setInsets(WindowInsetsCompat.Type.systemGestures(), Insets.of(0, top, 0, bottom))
            .setInsets(WindowInsetsCompat.Type.mandatorySystemGestures(), Insets.of(0, top, 0, bottom))
            .build()
        ViewCompat.dispatchApplyWindowInsets(view, insets)
    }

    /** Translucent red bands where the status bar and the nav bar / taskbar would be. */
    private fun addInsetBands(activity: ComponentActivity, root: ViewGroup) {
        val d = activity.resources.displayMetrics.density
        val band = object : View(activity) {
            private val p = Paint().apply { color = Color.argb(90, 255, 0, 0) }
            override fun onDraw(canvas: Canvas) {
                canvas.drawRect(0f, 0f, width.toFloat(), cfg.statusDp * d, p)
                canvas.drawRect(0f, height - cfg.navDp * d, width.toFloat(), height.toFloat(), p)
            }
        }
        root.addView(band, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    private fun swipeLeft(view: View) {
        val y = view.height / 2f
        val x0 = view.width * 0.85f
        val x1 = view.width * 0.15f
        val t0 = SystemClock.uptimeMillis()
        view.dispatchTouchEvent(MotionEvent.obtain(t0, t0, MotionEvent.ACTION_DOWN, x0, y, 0))
        for (i in 1..10) {
            view.dispatchTouchEvent(MotionEvent.obtain(t0, t0 + i * 16L, MotionEvent.ACTION_MOVE, x0 + (x1 - x0) * i / 10, y, 0))
        }
        view.dispatchTouchEvent(MotionEvent.obtain(t0, t0 + 180, MotionEvent.ACTION_UP, x1, y, 0))
    }

    private fun swipeUp(view: View) {
        val x = view.width / 2f
        val y0 = view.height * 0.85f
        val y1 = view.height * 0.15f
        val t0 = SystemClock.uptimeMillis()
        view.dispatchTouchEvent(MotionEvent.obtain(t0, t0, MotionEvent.ACTION_DOWN, x, y0, 0))
        val steps = 20
        for (i in 1..steps) {
            val y = y0 + (y1 - y0) * i / steps
            view.dispatchTouchEvent(MotionEvent.obtain(t0, t0 + i * 16L, MotionEvent.ACTION_MOVE, x, y, 0))
        }
        // Hold still before lifting so there is no fling; position stays deterministic.
        view.dispatchTouchEvent(MotionEvent.obtain(t0, t0 + steps * 16L + 200, MotionEvent.ACTION_MOVE, x, y1, 0))
        view.dispatchTouchEvent(MotionEvent.obtain(t0, t0 + steps * 16L + 220, MotionEvent.ACTION_UP, x, y1, 0))
    }
}

private fun log(msg: String) {
    val f = java.io.File("build/outputs/roborazzi/progress.log")
    f.parentFile?.mkdirs()
    f.appendText("${java.time.LocalTime.now()} $msg\n")
}

private object NoInfiniteAnimations : InfiniteAnimationPolicy {
    override suspend fun <R> onInfiniteOperation(block: suspend () -> R): R =
        throw CancellationException("Infinite animations are disabled in screenshot tests")
}

/** Same scenes on the API 37 sandbox, where ACCESS_LOCAL_NETWORK is a runtime permission (not granted). */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [37])
class Api37ScreenshotTest(private val cfg: DeviceMatrixScreenshotTest.ShotConfig) {
    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}")
        fun configs(): List<Array<Any>> = listOf(
            DeviceMatrixScreenshotTest.ShotConfig("api37_tabS8_land", "w1280dp-h800dp-land-xhdpi", navDp = 56),
            DeviceMatrixScreenshotTest.ShotConfig("api37_phone_port", "w411dp-h914dp-port-420dpi", navDp = 24),
        ).map { arrayOf<Any>(it) }
    }

    @Test
    fun localNetworkUi() = DeviceMatrixScreenshotTest(cfg).api37Scenes()
}
