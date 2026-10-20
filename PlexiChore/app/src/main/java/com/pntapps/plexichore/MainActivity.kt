package com.pntapps.plexichore

import android.content.pm.ApplicationInfo
import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.windowsizeclass.ExperimentalMaterial3WindowSizeClassApi
import androidx.compose.material3.windowsizeclass.calculateWindowSizeClass
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pntapps.plexichore.ui.MainViewModel
import com.pntapps.plexichore.ui.navigation.PlexiApp
import com.pntapps.plexichore.ui.theme.PlexiChoreTheme
import com.pntapps.plexichore.ui.theme.ThemeMode

class MainActivity : ComponentActivity() {
    private val vm: MainViewModel by viewModels()

    @OptIn(ExperimentalMaterial3WindowSizeClassApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        val splash = installSplashScreen()
        super.onCreate(savedInstanceState)
        splash.setKeepOnScreenCondition { vm.prefs.value == null }

        // Debug/demo hook: `adb shell am start -n com.pntapps.plexichore/.MainActivity --ez demo true`
        val debuggable = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (debuggable && intent?.hasExtra(EXTRA_DEMO) == true) vm.setDemoMode(intent.getBooleanExtra(EXTRA_DEMO, false))
        if (debuggable && intent?.getBooleanExtra(EXTRA_RESET_ONBOARDING, false) == true) vm.resetOnboarding()

        enableEdgeToEdge()
        setContent {
            val prefs by vm.prefs.collectAsStateWithLifecycle()
            val mode = prefs?.themeMode ?: ThemeMode.SYSTEM
            val dark = when (mode) { ThemeMode.SYSTEM -> isSystemInDarkTheme(); ThemeMode.DARK -> true; ThemeMode.LIGHT -> false }
            DisposableEffect(dark) {
                enableEdgeToEdge(
                    statusBarStyle = if (dark) SystemBarStyle.dark(Color.TRANSPARENT) else SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT),
                    navigationBarStyle = if (dark) SystemBarStyle.dark(Color.TRANSPARENT) else SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT),
                )
                onDispose {}
            }
            PlexiChoreTheme(themeMode = mode, dynamicColor = prefs?.dynamicColor == true) {
                PlexiApp(vm, calculateWindowSizeClass(this))
            }
        }
    }

    companion object {
        const val EXTRA_DEMO = "demo"
        const val EXTRA_RESET_ONBOARDING = "resetOnboarding"
    }
}
