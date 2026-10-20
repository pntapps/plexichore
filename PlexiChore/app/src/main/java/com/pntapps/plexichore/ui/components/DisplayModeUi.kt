package com.pntapps.plexichore.ui.components

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ScreenShare
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.automirrored.rounded.ViewQuilt
import com.pntapps.plexichore.core.DisplayMode

/** Shared labels/icons/descriptions for the three display modes. */
val displayModeOptions = listOf(
    SegmentOption(DisplayMode.EXTEND, "Extend", Icons.AutoMirrored.Rounded.ViewQuilt),
    SegmentOption(DisplayMode.PRIMARY, "Primary", Icons.Rounded.Star),
    SegmentOption(DisplayMode.MIRROR, "Mirror", Icons.AutoMirrored.Rounded.ScreenShare),
)

val DisplayMode.description: String
    get() = when (this) {
        DisplayMode.EXTEND -> "Adds the tablet as a second monitor next to your main display."
        DisplayMode.PRIMARY -> "Makes the tablet your computer's main screen — taskbar and desktop move to the tablet."
        DisplayMode.MIRROR -> "Shows an existing screen on the tablet."
    }

val DisplayMode.sessionLabel: String
    get() = when (this) {
        DisplayMode.EXTEND -> "Extended"
        DisplayMode.PRIMARY -> "Primary display"
        DisplayMode.MIRROR -> "Mirrored"
    }

/** Modes where the tablet sits beside a physical monitor (position matters). */
val DisplayMode.usesPosition: Boolean get() = this != DisplayMode.MIRROR

/** One-line caption under the Home hero illustration (what the animation shows). */
val DisplayMode.heroCaption: String
    get() = when (this) {
        DisplayMode.EXTEND -> "Your desktop continues onto the tablet"
        DisplayMode.PRIMARY -> "The tablet becomes your main screen"
        DisplayMode.MIRROR -> "The tablet shows the same screen"
    }
