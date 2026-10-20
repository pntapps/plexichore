package com.pntapps.plexichore.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

enum class ThemeMode { SYSTEM, DARK, LIGHT }

private fun schemeFrom(p: PlexiColors): ColorScheme =
    if (p.isDark) darkColorScheme(
        primary = p.accentStart,
        onPrimary = Color.White,
        primaryContainer = p.accentStart.copy(alpha = 0.22f),
        onPrimaryContainer = p.textPrimary,
        secondary = p.accentEnd,
        onSecondary = Ink950,
        tertiary = Magenta,
        background = p.background,
        onBackground = p.textPrimary,
        surface = Ink850,
        onSurface = p.textPrimary,
        surfaceVariant = Ink800,
        onSurfaceVariant = p.textSecondary,
        surfaceContainer = Ink850,
        surfaceContainerHigh = Ink800,
        surfaceContainerHighest = Color(0xFF1A2244),
        outline = Color.White.copy(alpha = 0.18f),
        outlineVariant = Color.White.copy(alpha = 0.08f),
        error = p.danger,
        inverseSurface = p.textPrimary,
        inverseOnSurface = Ink900,
    ) else lightColorScheme(
        primary = p.accentStart,
        onPrimary = Color.White,
        primaryContainer = p.accentStart.copy(alpha = 0.14f),
        onPrimaryContainer = p.textPrimary,
        secondary = p.accentEnd,
        onSecondary = Color.White,
        tertiary = Magenta,
        background = p.background,
        onBackground = p.textPrimary,
        surface = Color.White,
        onSurface = p.textPrimary,
        surfaceVariant = Mist100,
        onSurfaceVariant = p.textSecondary,
        surfaceContainer = Color.White,
        surfaceContainerHigh = Color.White,
        surfaceContainerHighest = Mist100,
        outline = Color(0xFF1B2250).copy(alpha = 0.18f),
        outlineVariant = Color(0xFF1B2250).copy(alpha = 0.08f),
        error = p.danger,
    )

val PlexiShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(12.dp),
    medium = RoundedCornerShape(18.dp),
    large = RoundedCornerShape(24.dp),
    extraLarge = RoundedCornerShape(32.dp),
)

@Composable
fun PlexiChoreTheme(
    themeMode: ThemeMode = ThemeMode.SYSTEM,
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit,
) {
    val dark = when (themeMode) {
        ThemeMode.SYSTEM -> isSystemInDarkTheme()
        ThemeMode.DARK -> true
        ThemeMode.LIGHT -> false
    }
    val plexi = if (dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        val ctx = LocalContext.current
        val dyn = if (dark) dynamicDarkColorScheme(ctx) else dynamicLightColorScheme(ctx)
        if (dark) darkPlexiColors(dyn.primary, dyn.tertiary) else lightPlexiColors(dyn.primary, dyn.tertiary)
    } else if (dark) darkPlexiColors() else lightPlexiColors()

    CompositionLocalProvider(LocalPlexiColors provides plexi) {
        MaterialTheme(
            colorScheme = schemeFrom(plexi),
            typography = Typography,
            shapes = PlexiShapes,
            content = content,
        )
    }
}

object Plexi {
    val colors: PlexiColors
        @Composable @ReadOnlyComposable get() = LocalPlexiColors.current
}
