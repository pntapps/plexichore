package com.pntapps.plexichore.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

/* ---------- Brand palette ---------- */
val Violet = Color(0xFF7C5CFF)
val VioletDeep = Color(0xFF5B3DF5)
val Cyan = Color(0xFF22D3EE)
val Magenta = Color(0xFFD946EF)
val Mint = Color(0xFF34D399)
val Amber = Color(0xFFFBBF24)
val Coral = Color(0xFFFF6B7A)

val Ink950 = Color(0xFF05070F)
val Ink900 = Color(0xFF080B17)
val Ink850 = Color(0xFF0C1122)
val Ink800 = Color(0xFF121933)
val Mist50 = Color(0xFFF6F7FC)
val Mist100 = Color(0xFFECEFF8)

/**
 * Extended, PlexiChore-specific color tokens that Material's ColorScheme doesn't model
 * (glass surfaces, aurora glow, accent gradient).
 */
@Immutable
data class PlexiColors(
    val isDark: Boolean,
    val background: Color,
    val backgroundAlt: Color,
    val glass: Color,
    val glassStrong: Color,
    val glassBorder: Color,
    val glassBorderHighlight: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val textTertiary: Color,
    val accentStart: Color,
    val accentEnd: Color,
    val accentMid: Color,
    val aurora1: Color,
    val aurora2: Color,
    val aurora3: Color,
    val success: Color,
    val warning: Color,
    val danger: Color,
    val gridDot: Color,
) {
    val accentBrush: Brush get() = Brush.linearGradient(listOf(accentStart, accentEnd))
    val accentBrushVertical: Brush get() = Brush.verticalGradient(listOf(accentStart, accentEnd))
}

fun darkPlexiColors(accentStart: Color = Violet, accentEnd: Color = Cyan) = PlexiColors(
    isDark = true,
    background = Ink900,
    backgroundAlt = Ink950,
    glass = Color(0xFFFFFFFF).copy(alpha = 0.045f),
    glassStrong = Color(0xFF141A34).copy(alpha = 0.96f),
    glassBorder = Color.White.copy(alpha = 0.08f),
    glassBorderHighlight = Color.White.copy(alpha = 0.20f),
    textPrimary = Color(0xFFF2F4FF),
    textSecondary = Color(0xFFA8B0CC),
    textTertiary = Color(0xFF6B7394),
    accentStart = accentStart,
    accentEnd = accentEnd,
    accentMid = Color(0xFF5E8BFF),
    aurora1 = accentStart.copy(alpha = 0.34f),
    aurora2 = accentEnd.copy(alpha = 0.20f),
    aurora3 = Magenta.copy(alpha = 0.16f),
    success = Mint,
    warning = Amber,
    danger = Coral,
    gridDot = Color.White.copy(alpha = 0.035f),
)

fun lightPlexiColors(accentStart: Color = VioletDeep, accentEnd: Color = Color(0xFF06B6D4)) = PlexiColors(
    isDark = false,
    background = Mist50,
    backgroundAlt = Mist100,
    glass = Color.White.copy(alpha = 0.66f),
    glassStrong = Color.White.copy(alpha = 0.92f),
    glassBorder = Color(0xFF1B2250).copy(alpha = 0.08f),
    glassBorderHighlight = Color.White.copy(alpha = 0.95f),
    textPrimary = Color(0xFF0D1230),
    textSecondary = Color(0xFF4A5275),
    textTertiary = Color(0xFF8189A8),
    accentStart = accentStart,
    accentEnd = accentEnd,
    accentMid = Color(0xFF3B6CF6),
    aurora1 = accentStart.copy(alpha = 0.20f),
    aurora2 = accentEnd.copy(alpha = 0.18f),
    aurora3 = Magenta.copy(alpha = 0.10f),
    success = Color(0xFF059669),
    warning = Color(0xFFD97706),
    danger = Color(0xFFE11D48),
    gridDot = Color(0xFF1B2250).copy(alpha = 0.05f),
)

val LocalPlexiColors = staticCompositionLocalOf { darkPlexiColors() }
