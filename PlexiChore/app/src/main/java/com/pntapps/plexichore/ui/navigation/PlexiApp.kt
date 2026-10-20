package com.pntapps.plexichore.ui.navigation

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.windowsizeclass.WindowSizeClass
import androidx.compose.material3.windowsizeclass.WindowWidthSizeClass
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pntapps.plexichore.ui.MainViewModel
import com.pntapps.plexichore.ui.components.AuroraBackground
import com.pntapps.plexichore.ui.screens.ConnectionOverlay
import com.pntapps.plexichore.ui.screens.HelpScreen
import com.pntapps.plexichore.ui.screens.HomeScreen
import com.pntapps.plexichore.ui.screens.OnboardingScreen
import com.pntapps.plexichore.ui.screens.SettingsScreen

enum class Screen { HOME, SETTINGS, HELP }

/**
 * Layout facts derived from the *window* size (split-screen, freeform and DeX windows count).
 * [compactHeight] = short windows (phones in landscape, 7" tablets in landscape at large font,
 * split-screen top/bottom): illustrations shrink and everything must scroll.
 */
data class AdaptiveInfo(
    val twoPane: Boolean,
    val expandedWidth: Boolean,
    val compactHeight: Boolean = false,
)

val LocalAdaptive = compositionLocalOf { AdaptiveInfo(twoPane = true, expandedWidth = true) }

/**
 * Two panes need width (≥ 720dp: 7" tablets in landscape, foldable inner screens) *and* height
 * (≥ 480dp, so phones in landscape stay single-column) and a landscape-ish window. Large font
 * scales raise the width threshold so 200% text still gets usable columns.
 */
fun adaptiveInfo(widthDp: Int, heightDp: Int, fontScale: Float = 1f): AdaptiveInfo {
    val fs = fontScale.coerceIn(1f, 2f)
    val minPaneWidth = 720f * (1f + (fs - 1f) * 0.35f)
    val twoPane = widthDp >= minPaneWidth && heightDp >= 480 && widthDp >= heightDp * 1.05f
    return AdaptiveInfo(
        twoPane = twoPane,
        expandedWidth = widthDp >= 840,
        compactHeight = heightDp < 600 || heightDp / fs < 420f,
    )
}

@Composable
fun PlexiApp(vm: MainViewModel, @Suppress("UNUSED_PARAMETER") windowSize: WindowSizeClass) {
    val prefs by vm.prefs.collectAsStateWithLifecycle()
    val p = prefs ?: return
    val config = LocalConfiguration.current
    val adaptive = adaptiveInfo(config.screenWidthDp, config.screenHeightDp, config.fontScale)

    CompositionLocalProvider(LocalAdaptive provides adaptive) {
        AuroraBackground(Modifier.fillMaxSize()) {
            AnimatedContent(
                targetState = p.onboardingDone,
                transitionSpec = { (fadeIn(tween(500)) + scaleIn(initialScale = 1.04f)) togetherWith fadeOut(tween(300)) },
                label = "root",
            ) { done ->
                if (!done) OnboardingScreen(onFinish = { vm.completeOnboarding() })
                else MainNav(vm)
            }
        }
    }
}

@Composable
private fun MainNav(vm: MainViewModel) {
    val stack = rememberSaveable(
        saver = listSaver(save = { it.map(Screen::name) }, restore = { mutableStateListOf(*it.map(Screen::valueOf).toTypedArray()) }),
    ) { mutableStateListOf(Screen.HOME) }
    val current = stack.last()
    val navigate: (Screen) -> Unit = { if (stack.last() != it) stack.add(it) }
    val back: () -> Unit = { if (stack.size > 1) stack.removeAt(stack.lastIndex) }
    BackHandler(enabled = stack.size > 1, onBack = back)

    Box(Modifier.fillMaxSize()) {
        AnimatedContent(
            targetState = current,
            transitionSpec = {
                val forward = targetState.ordinal > initialState.ordinal
                val dir = if (forward) 1 else -1
                (slideInHorizontally(tween(420)) { w -> dir * w / 6 } + fadeIn(tween(420))) togetherWith
                    (slideOutHorizontally(tween(320)) { w -> -dir * w / 8 } + fadeOut(tween(260)))
            },
            label = "nav",
        ) { screen ->
            when (screen) {
                Screen.HOME -> HomeScreen(vm, onOpenSettings = { navigate(Screen.SETTINGS) }, onOpenHelp = { navigate(Screen.HELP) })
                Screen.SETTINGS -> SettingsScreen(vm, onBack = back, onOpenHelp = { navigate(Screen.HELP) })
                Screen.HELP -> HelpScreen(onBack = back)
            }
        }
        ConnectionOverlay(vm, onOpenHelp = { vm.cancel(); navigate(Screen.HELP) })
    }
}
