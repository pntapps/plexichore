package com.pntapps.plexichore.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.graphicsLayer
import com.pntapps.plexichore.ui.theme.Plexi
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin

/**
 * Deep background with a slowly drifting aurora mesh (three soft radial glows) and a faint
 * dot grid. Cheap: a few radial gradients per frame on their own layer, no blur.
 */
@Composable
fun AuroraBackground(
    modifier: Modifier = Modifier,
    intensity: Float = 1f,
    content: @Composable BoxScope.() -> Unit,
) {
    val c = Plexi.colors
    val t = rememberInfiniteTransition(label = "aurora")
    val phase by t.animateFloat(
        0f, (2 * PI).toFloat(),
        infiniteRepeatable(tween(26_000, easing = LinearEasing), RepeatMode.Restart), label = "phase",
    )
    Box(modifier.background(Brush.verticalGradient(listOf(c.background, c.backgroundAlt)))) {
        Canvas(Modifier.matchParentSize().graphicsLayer()) { drawDotGrid(c.gridDot) }
        Canvas(Modifier.matchParentSize().graphicsLayer()) {
            val w = size.width; val h = size.height; val r = max(w, h)
            glow(c.aurora1.scaled(intensity), Offset(w * (0.18f + 0.08f * cos(phase)), h * (0.12f + 0.10f * sin(phase))), r * 0.55f)
            glow(c.aurora2.scaled(intensity), Offset(w * (0.88f + 0.06f * sin(phase * 2)), h * (0.30f + 0.12f * cos(phase))), r * 0.45f)
            glow(c.aurora3.scaled(intensity), Offset(w * (0.55f + 0.12f * cos(phase + 1.7f)), h * (1.02f + 0.06f * sin(phase))), r * 0.50f)
        }
        content()
    }
}

private fun Color.scaled(f: Float) = copy(alpha = (alpha * f).coerceIn(0f, 1f))

private fun DrawScope.glow(color: Color, center: Offset, radius: Float) {
    drawCircle(
        brush = Brush.radialGradient(
            0f to color, 0.45f to color.copy(alpha = color.alpha * 0.45f), 1f to Color.Transparent,
            center = center, radius = radius,
        ),
        radius = radius, center = center,
    )
}

private fun DrawScope.drawDotGrid(color: Color) {
    val step = 28f * density
    val rad = 1.1f * density
    var y = step / 2
    while (y < size.height) {
        var x = step / 2
        while (x < size.width) {
            drawCircle(color, rad, Offset(x, y))
            x += step
        }
        y += step
    }
}
