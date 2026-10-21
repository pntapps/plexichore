package com.pntapps.plexichore.display

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.RectF
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Display
import android.view.KeyEvent
import android.view.SurfaceHolder
import android.view.ViewGroup
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import com.pntapps.plexichore.MainActivity
import com.pntapps.plexichore.core.ConnectionState
import com.pntapps.plexichore.core.DisplayMode
import com.pntapps.plexichore.core.EncodedInput
import com.pntapps.plexichore.core.PlexiCore
import com.pntapps.plexichore.core.PlexiCoreConnection
import com.pntapps.plexichore.core.StreamSettings
import com.pntapps.plexichore.core.TouchMode
import com.pntapps.plexichore.ui.components.DisplayScaleUi
import com.pntapps.plexichore.ui.data.KeyboardBubblePos
import com.pntapps.plexichore.ui.data.SettingsRepository
import com.pntapps.plexichore.ui.theme.PlexiChoreTheme
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Full-screen, immersive video surface for an active session. Launched by the core when the
 * host sends CONFIG; finishes (back to [MainActivity]) when the session ends or fails.
 *
 * Debug builds also accept a direct connection request through the exported debug-only alias:
 * `am start -n com.pntapps.plexichore/.display.DebugDisplay --es host 127.0.0.1 [--ei port 47800]
 *  [--es codec mjpeg|h264] [--ei fps 60] [--ei bitrate 20000] [--es mode extend|mirror] [--ei scale 0|100..300] [--ef resScale 0.75]`
 */
class DisplayActivity : ComponentActivity() {

    private lateinit var core: PlexiCoreConnection
    private lateinit var layout: StreamLayout
    private lateinit var keyboard: StreamKeyboard

    private val controlsVisible = mutableStateOf(false)
    private val showHint = mutableStateOf(false)
    private val hasStreamed = mutableStateOf(false)
    private val orientationHint = mutableStateOf(false)
    private val regions = HashMap<String, RectF>()
    private val persistentRegions = HashMap<String, RectF>()
    private var restoreKeyboard = false
    private var imeBottomPx = 0
    private val bubbleLand = mutableStateOf(KeyboardBubblePos())
    private val bubblePort = mutableStateOf(KeyboardBubblePos())
    private var hideJob: Job? = null
    private var currentCodec: String? = null
    private var hintShown = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        core = PlexiCore.impl(this)
        if (savedInstanceState == null) handleDebugIntent(intent)
        if (core.state.value.isTerminal()) {
            finish()
            return
        }
        alive = true
        restoreKeyboard = savedInstanceState?.getBoolean(STATE_KEYBOARD) == true

        // The video never resizes or pans for the soft keyboard (that would change the viewport the
        // host builds its display from); the keyboard UI follows the IME insets instead.
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING or WindowManager.LayoutParams.SOFT_INPUT_STATE_HIDDEN)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= 30) {
            window.attributes.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        } else if (Build.VERSION.SDK_INT >= 28) {
            window.attributes.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        preferHighestRefreshRate()
        WindowCompat.setDecorFitsSystemWindows(window, false)
        enterImmersive()

        layout = StreamLayout(this, streamCallbacks)
        keyboard = StreamKeyboard(
            this,
            send = { action, code, text -> core.sendKey(action, code, text) },
            isStreaming = { core.state.value is ConnectionState.Streaming },
        )
        keyboard.onOpenChanged = { open -> if (!open) layout.keepTouchVisible(null, 0f) }
        layout.addView(keyboard.sink, ViewGroup.LayoutParams(1, 1))
        val repo = SettingsRepository.get(this)
        lifecycleScope.launch { repo.keyboardBubble(landscape = true).collect { bubbleLand.value = it } }
        lifecycleScope.launch { repo.keyboardBubble(landscape = false).collect { bubblePort.value = it } }
        val overlay = ComposeView(this).apply {
            // The overlay never takes focus: the keyboard sink must keep it, or the IME would close.
            descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
            isFocusable = false
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed)
            setContent {
                val state by core.state.collectAsState()
                val stats by core.stats.collectAsState()
                val settings by core.settings.collectAsState()
                PlexiChoreTheme {
                    DisplayOverlay(
                        state = state,
                        stats = stats,
                        settings = settings,
                        controlsVisible = controlsVisible.value,
                        showHint = showHint.value,
                        hasStreamed = hasStreamed.value,
                        onDisconnect = { core.disconnect() },
                        onToggleStats = {
                            core.updateSettings(core.settings.value.let { it.copy(showStatsOverlay = !it.showStatsOverlay) })
                            scheduleHide()
                        },
                        onCycleTouchMode = {
                            core.updateSettings(core.settings.value.let { it.copy(touchMode = it.touchMode.next()) })
                            scheduleHide()
                        },
                        onRegion = ::onRegion,
                        orientationHint = orientationHint.value,
                        onSetScale = { next ->
                            core.updateSettings(core.settings.value.copy(scalePercent = next))
                            lifecycleScope.launch { SettingsRepository.get(this@DisplayActivity).updateStream { it.copy(scalePercent = next) } }
                            scheduleHide()
                        },
                        keyboard = KeyboardOverlayState(
                            open = keyboard.open.value,
                            showBubble = settings.showKeyboardButton,
                            armed = keyboard.armed.value,
                            locked = keyboard.locked.value,
                            bubbleLandscape = bubbleLand.value,
                            bubblePortrait = bubblePort.value,
                            keysAtTop = Build.VERSION.SDK_INT < 30,
                        ),
                        keyboardActions = keyboardActions,
                    )
                }
            }
        }
        layout.addView(overlay, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        setContentView(layout)

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                // Never leave the session by accident: back closes the keyboard, else toggles the controls.
                if (keyboard.open.value) keyboard.hide() else setControlsVisible(!controlsVisible.value)
            }
        })

        lifecycleScope.launch { core.state.collect(::onState) }
        lifecycleScope.launch {
            core.settings.collectLatest { s ->
                if (s.keepScreenOn) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleDebugIntent(intent)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) enterImmersive() else if (::keyboard.isInitialized) keyboard.releaseHardwareKeys()
    }

    override fun onPause() {
        if (::keyboard.isInitialized) keyboard.releaseHardwareKeys()
        super.onPause()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        if (::keyboard.isInitialized) outState.putBoolean(STATE_KEYBOARD, keyboard.open.value)
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        if (::keyboard.isInitialized) keyboard.onConfigurationChanged()
    }

    /** Physical keyboards go to the host while streaming (system keys and the nav bar's Back stay local). */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (::keyboard.isInitialized && keyboard.onHardwareKey(event)) return true
        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        if (::layout.isInitialized) {
            core.pipeline.clearSurface(layout.surfaceView.holder.surface)
            alive = false
        }
        super.onDestroy()
    }

    private fun onState(state: ConnectionState) {
        when (state) {
            is ConnectionState.Streaming -> {
                val c = state.config
                if (currentCodec != null && currentCodec != c.codec) {
                    // MediaCodec and the MJPEG canvas cannot share a Surface: swap the view.
                    layout.recreateSurface()
                }
                currentCodec = c.codec
                layout.setVideoSize(c.width, c.height)
                orientationHint.value = core.orientationMismatch(c)
                layout.forwardInput = true
                hasStreamed.value = true
                if (restoreKeyboard) {
                    // Recreated while the keyboard was open (e.g. rotation with recreation): bring it back.
                    restoreKeyboard = false
                    layout.post { keyboard.show() }
                }
                if (!hintShown) {
                    hintShown = true
                    maybeShowHint()
                }
            }
            is ConnectionState.Connecting, is ConnectionState.AwaitingApproval -> {
                layout.forwardInput = false
                setControlsVisible(false)
                keyboard.onSessionEnded()
            }
            ConnectionState.Idle, is ConnectionState.Failed -> {
                keyboard.onSessionEnded()
                close()
            }
        }
    }

    private fun close() {
        if (isFinishing) return
        if (isTaskRoot) {
            startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP))
        }
        finish()
    }

    // ---- Controls ------------------------------------------------------------------------

    private fun setControlsVisible(visible: Boolean) {
        controlsVisible.value = visible
        layout.controlsVisible = visible
        if (visible) {
            showHint.value = false
            scheduleHide()
        } else {
            hideJob?.cancel()
        }
    }

    private fun scheduleHide() {
        hideJob?.cancel()
        hideJob = lifecycleScope.launch {
            delay(CONTROLS_TIMEOUT_MS)
            setControlsVisible(false)
        }
    }

    private fun maybeShowHint() {
        val prefs = getSharedPreferences("plexi_display", MODE_PRIVATE)
        val count = prefs.getInt("hint_count", 0)
        if (count >= 3) return
        prefs.edit().putInt("hint_count", count + 1).apply()
        lifecycleScope.launch {
            delay(600)
            showHint.value = true
            delay(4_000)
            showHint.value = false
        }
    }

    private fun onRegion(key: String, bounds: androidx.compose.ui.geometry.Rect?) {
        val map = if (key in PERSISTENT_REGIONS) persistentRegions else regions
        if (bounds == null) map.remove(key)
        else map[key] = RectF(bounds.left, bounds.top, bounds.right, bounds.bottom).apply { inset(-8f, -8f) }
        layout.interactiveRegions = regions.values.toList()
        layout.persistentRegions = persistentRegions.values.toList()
        if (key == REGION_KEYS) updateVideoShift()
    }

    /** Keeps the field being typed into (last touch) visible above the keys row while the IME is up. */
    private fun updateVideoShift() {
        val row = persistentRegions[REGION_KEYS]
        if (!keyboard.open.value || imeBottomPx <= 0 || row == null) {
            layout.keepTouchVisible(null, 0f)
            return
        }
        // Row top as laid out above the final IME height (the row itself may still be animating in).
        val rowTop = minOf(row.top + 8f, layout.height - imeBottomPx - (row.height() - 16f))
        layout.keepTouchVisible(rowTop, 24 * resources.displayMetrics.density)
    }

    private val keyboardActions = object : KeyboardActions {
        override fun toggle() {
            keyboard.toggle()
            if (controlsVisible.value) scheduleHide()
        }
        override fun hide() = keyboard.hide()
        override fun press(keyCode: Int, consume: Boolean) = keyboard.press(keyCode, consume)
        override fun release() = keyboard.release()
        override fun toggleModifier(m: StickyModifier) = keyboard.toggleModifier(m)
        override fun moveBubble(landscape: Boolean, pos: KeyboardBubblePos) {
            (if (landscape) bubbleLand else bubblePort).value = pos
            lifecycleScope.launch { SettingsRepository.get(this@DisplayActivity).setKeyboardBubble(landscape, pos) }
        }
    }

    // ---- StreamLayout.Callbacks ----------------------------------------------------------

    private val streamCallbacks = object : StreamLayout.Callbacks {
        override fun onInput(input: EncodedInput) = core.sendInput(input)

        override fun onViewportChanged(widthPx: Int, heightPx: Int) {
            core.onViewportChanged(widthPx, heightPx)
            (core.state.value as? ConnectionState.Streaming)?.let { orientationHint.value = core.orientationMismatch(it.config) }
        }

        override fun onImeChanged(visible: Boolean, bottomPx: Int) {
            imeBottomPx = if (visible) bottomPx else 0
            keyboard.onImeVisibilityChanged(visible)
            updateVideoShift()
        }

        override fun onControlsGesture(toggle: Boolean) {
            setControlsVisible(if (toggle) !controlsVisible.value else true)
        }

        override fun surfaceCreated(holder: SurfaceHolder) {
            core.pipeline.setSurface(holder.surface)
        }

        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit

        override fun surfaceDestroyed(holder: SurfaceHolder) {
            core.pipeline.clearSurface(holder.surface)
        }
    }

    // ---- Window --------------------------------------------------------------------------

    private fun enterImmersive() {
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    private fun preferHighestRefreshRate() {
        @Suppress("DEPRECATION")
        val display: Display = (if (Build.VERSION.SDK_INT >= 30) display else windowManager.defaultDisplay) ?: return
        val current = display.mode
        val best = display.supportedModes
            .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
            .maxByOrNull { it.refreshRate } ?: return
        if (best.modeId != current.modeId) {
            window.attributes = window.attributes.apply { preferredDisplayModeId = best.modeId }
        }
    }

    // ---- Debug entry ---------------------------------------------------------------------

    private fun handleDebugIntent(intent: Intent?) {
        if (intent == null || applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) return
        // `--ez discover true`: start discovery; results are logged under tag PlexiDiscovery.
        if (intent.getBooleanExtra("discover", false)) core.startDiscovery()
        val host = intent.getStringExtra(EXTRA_HOST) ?: return
        val base = StreamSettings()
        val settings = base.copy(
            codec = intent.getStringExtra("codec") ?: base.codec,
            fps = intent.getIntExtra("fps", base.fps),
            bitrateKbps = intent.getIntExtra("bitrate", base.bitrateKbps),
            mode = when (intent.getStringExtra("mode")) { "mirror" -> DisplayMode.MIRROR; "primary" -> DisplayMode.PRIMARY; else -> DisplayMode.EXTEND },
            showStatsOverlay = intent.getBooleanExtra("stats", true),
            scalePercent = intent.getIntExtra("scale", base.scalePercent),
            resolutionScale = intent.getFloatExtra("resScale", base.resolutionScale),
        )
        Log.i(TAG, "Debug connect to $host with $settings")
        intent.removeExtra(EXTRA_HOST)
        core.connectManual(host, intent.getIntExtra("port", 47800), settings)
    }

    companion object {
        private const val TAG = "PlexiDisplay"
        private const val EXTRA_HOST = "host"
        private const val CONTROLS_TIMEOUT_MS = 4_000L
        private const val STATE_KEYBOARD = "keyboard_open"
        private const val REGION_KEYS = "kbRow"
        private val PERSISTENT_REGIONS = setOf("kbBubble", REGION_KEYS)

        /** True while an instance is on screen or in the back stack. */
        @Volatile
        internal var alive = false
            private set

        private fun ConnectionState.isTerminal() = this is ConnectionState.Idle || this is ConnectionState.Failed

        private fun TouchMode.next() = when (this) {
            TouchMode.TOUCH -> TouchMode.MOUSE
            TouchMode.MOUSE -> TouchMode.NONE
            TouchMode.NONE -> TouchMode.TOUCH
        }
    }
}
