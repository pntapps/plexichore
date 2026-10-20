package com.pntapps.plexichore.ui.components

import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.tappableElement
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp

/**
 * Everything content must stay clear of: system bars, display cutout, IME **and** tappable
 * elements. The last one matters on large screens: the Samsung One UI / Android 12L+ taskbar is
 * reported as `tappableElement` (navigationBars can be only the gesture handle, or 0).
 */
val WindowInsets.Companion.plexiSafe: WindowInsets
    @Composable get() = WindowInsets.safeDrawing.union(WindowInsets.tappableElement)

/** Top + start/end safe padding for a screen root (the bottom goes into scrollable content). */
@Composable
fun Modifier.plexiSafeTopAndSides(): Modifier =
    windowInsetsPadding(WindowInsets.plexiSafe.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal))

/** All-sides safe padding (non-scrolling full-screen content such as onboarding and overlays). */
@Composable
fun Modifier.plexiSafeAll(): Modifier = windowInsetsPadding(WindowInsets.plexiSafe)

/** Bottom padding for scrollable content so its end clears the nav bar / taskbar. */
@Composable
fun safeBottomPadding(): Dp =
    WindowInsets.plexiSafe.only(WindowInsetsSides.Bottom).asPaddingValues().calculateBottomPadding()
