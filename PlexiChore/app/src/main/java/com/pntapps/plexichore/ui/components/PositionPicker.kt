package com.pntapps.plexichore.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.VectorConverter
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Monitor
import androidx.compose.material.icons.rounded.TabletAndroid
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.pntapps.plexichore.core.Position
import com.pntapps.plexichore.ui.theme.Plexi
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Visual picker of where the tablet sits relative to the computer's main monitor.
 * Tap a dashed slot or drag the tablet tile; it springs to the nearest side.
 */
@Composable
fun PositionPicker(position: Position, onChange: (Position) -> Unit, modifier: Modifier = Modifier, monitorLabel: String = "Main display") {
    val c = Plexi.colors
    val haptic = androidx.compose.ui.platform.LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    BoxWithConstraints(
        modifier
            .fillMaxWidth()
            .aspectRatio(1.75f)
            .clip(RoundedCornerShape(20.dp))
            .background(if (c.isDark) Color.Black.copy(alpha = 0.25f) else c.backgroundAlt)
            .border(1.dp, c.glassBorder, RoundedCornerShape(20.dp)),
    ) {
        val density = LocalDensity.current
        val w = with(density) { maxWidth.toPx() }
        val h = with(density) { maxHeight.toPx() }
        val monW = w * 0.34f; val monH = monW * 0.6f
        val tabW = w * 0.22f; val tabH = tabW * 0.64f
        val gap = w * 0.03f
        val center = Offset(w / 2, h / 2)
        fun slot(p: Position): Offset = when (p) {
            Position.RIGHT -> Offset(center.x + monW / 2 + gap + tabW / 2, center.y)
            Position.LEFT -> Offset(center.x - monW / 2 - gap - tabW / 2, center.y)
            Position.TOP -> Offset(center.x, center.y - monH / 2 - gap - tabH / 2)
            Position.BOTTOM -> Offset(center.x, center.y + monH / 2 + gap + tabH / 2)
        }
        val anim = remember { Animatable(slot(position), Offset.VectorConverter) }
        LaunchedEffect(position, w, h) { anim.animateTo(slot(position), spring(dampingRatio = 0.62f, stiffness = Spring.StiffnessMediumLow)) }

        // dashed slots
        Box(
            Modifier.matchParentSize().drawBehind {
                Position.entries.forEach { p ->
                    if (p == position) return@forEach
                    val s = slot(p)
                    drawRoundRect(
                        c.textTertiary.copy(alpha = 0.45f),
                        Offset(s.x - tabW / 2, s.y - tabH / 2), androidx.compose.ui.geometry.Size(tabW, tabH), CornerRadius(10.dp.toPx()),
                        style = Stroke(1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 8f))),
                    )
                }
            },
        )
        Position.entries.forEach { p ->
            val s = slot(p)
            Box(
                Modifier
                    .offset { IntOffset((s.x - tabW / 2).roundToInt(), (s.y - tabH / 2).roundToInt()) }
                    .size(with(density) { tabW.toDp() }, with(density) { tabH.toDp() })
                    .clip(RoundedCornerShape(10.dp))
                    .clickable {
                        if (p != position) haptic.performHapticFeedback(HapticFeedbackType.SegmentTick)
                        onChange(p)
                    },
            )
        }
        // monitor
        Box(
            Modifier
                .offset { IntOffset((center.x - monW / 2).roundToInt(), (center.y - monH / 2).roundToInt()) }
                .size(with(density) { monW.toDp() }, with(density) { monH.toDp() })
                .clip(RoundedCornerShape(12.dp))
                .background(if (c.isDark) Color(0xFF1A2146) else Color.White)
                .border(1.dp, c.glassBorderHighlight.copy(alpha = 0.4f), RoundedCornerShape(12.dp)),
            contentAlignment = Alignment.Center,
        ) {
            androidx.compose.foundation.layout.Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Rounded.Monitor, null, tint = c.textSecondary, modifier = Modifier.size(22.dp))
                Text(monitorLabel, style = MaterialTheme.typography.labelMedium, color = c.textSecondary)
            }
        }
        // tablet (draggable)
        val o = anim.value
        Box(
            Modifier
                .offset { IntOffset((o.x - tabW / 2).roundToInt(), (o.y - tabH / 2).roundToInt()) }
                .size(with(density) { tabW.toDp() }, with(density) { tabH.toDp() })
                .clip(RoundedCornerShape(10.dp))
                .background(c.accentBrush)
                .background(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.22f), Color.Transparent)))
                .border(1.dp, Color.White.copy(alpha = 0.35f), RoundedCornerShape(10.dp))
                .pointerInput(w, h) {
                    detectDragGestures(
                        onDrag = { change, drag ->
                            change.consume()
                            scope.launch { anim.snapTo(anim.value + drag) }
                        },
                        onDragEnd = {
                            val d = anim.value - center
                            val target = if (abs(d.x) / (monW / 2 + tabW / 2) >= abs(d.y) / (monH / 2 + tabH / 2)) {
                                if (d.x >= 0) Position.RIGHT else Position.LEFT
                            } else if (d.y >= 0) Position.BOTTOM else Position.TOP
                            haptic.performHapticFeedback(HapticFeedbackType.GestureEnd)
                            onChange(target)
                            scope.launch { anim.animateTo(slot(target), spring(dampingRatio = 0.62f, stiffness = Spring.StiffnessMediumLow)) }
                        },
                    )
                },
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Rounded.TabletAndroid, null, tint = Color.White, modifier = Modifier.size(20.dp).graphicsLayer { rotationZ = 90f })
        }
    }
}
