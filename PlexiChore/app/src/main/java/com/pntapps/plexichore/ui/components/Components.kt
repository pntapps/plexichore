package com.pntapps.plexichore.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.pntapps.plexichore.ui.theme.Plexi

/* ---------------------------------------------------------------- Glass */

@Composable
fun Modifier.glassSurface(
    shape: Shape = RoundedCornerShape(24.dp),
    strong: Boolean = false,
    highlighted: Boolean = false,
): Modifier {
    val c = Plexi.colors
    val border = if (highlighted) Brush.linearGradient(listOf(c.accentStart.copy(alpha = 0.9f), c.accentEnd.copy(alpha = 0.7f)))
    else Brush.verticalGradient(listOf(c.glassBorderHighlight, c.glassBorder, c.glassBorder))
    return this
        .clip(shape)
        .background(if (strong) c.glassStrong else c.glass, shape)
        .background(
            Brush.verticalGradient(listOf(Color.White.copy(alpha = if (c.isDark) 0.035f else 0.25f), Color.Transparent)),
            shape,
        )
        .border(BorderStroke(if (highlighted) 1.5.dp else 1.dp, border), shape)
}

@Composable
fun GlassCard(
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(24.dp),
    strong: Boolean = false,
    highlighted: Boolean = false,
    contentPadding: PaddingValues = PaddingValues(20.dp),
    onClick: (() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val s by animateFloatAsState(if (pressed) 0.985f else 1f, spring(stiffness = Spring.StiffnessMediumLow), label = "press")
    Column(
        modifier
            .scale(s)
            .glassSurface(shape, strong, highlighted)
            .then(if (onClick != null) Modifier.clickable(interaction, null, onClick = onClick) else Modifier)
            .padding(contentPadding),
        content = content,
    )
}

/* ---------------------------------------------------------------- Text */

@Composable
fun GradientText(text: String, style: TextStyle, modifier: Modifier = Modifier, brush: Brush = Plexi.colors.accentBrush, textAlign: TextAlign? = null) {
    Text(
        text = text,
        style = style.copy(brush = brush),
        modifier = modifier,
        textAlign = textAlign,
    )
}

@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        color = Plexi.colors.textTertiary,
        modifier = modifier,
    )
}

/* ---------------------------------------------------------------- Buttons */

@Composable
fun GradientButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    enabled: Boolean = true,
    height: Dp = 52.dp,
) {
    val c = Plexi.colors
    val haptic = LocalHapticFeedback.current
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val s by animateFloatAsState(if (pressed) 0.96f else 1f, spring(dampingRatio = 0.55f, stiffness = Spring.StiffnessMedium), label = "btn")
    val shape = RoundedCornerShape(height / 2)
    Row(
        modifier
            .scale(s)
            .heightIn(min = height)
            .graphicsLayer { alpha = if (enabled) 1f else 0.45f }
            .shadow(if (enabled) 16.dp else 0.dp, shape, clip = false, ambientColor = c.accentStart, spotColor = c.accentStart)
            .clip(shape)
            .background(c.accentBrush)
            .background(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.18f), Color.Transparent)))
            .border(1.dp, Color.White.copy(alpha = 0.22f), shape)
            .clickable(interaction, null, enabled = enabled, role = Role.Button) {
                haptic.performHapticFeedback(HapticFeedbackType.Confirm)
                onClick()
            }
            .padding(horizontal = 22.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (icon != null) {
            Icon(icon, null, tint = Color.White, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(10.dp))
        }
        Text(text, style = MaterialTheme.typography.labelLarge, color = Color.White, textAlign = TextAlign.Center, modifier = Modifier.padding(vertical = 6.dp))
    }
}

@Composable
fun GhostButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    height: Dp = 48.dp,
    contentColor: Color = Plexi.colors.textPrimary,
) {
    val c = Plexi.colors
    val haptic = LocalHapticFeedback.current
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val s by animateFloatAsState(if (pressed) 0.96f else 1f, label = "ghost")
    val shape = RoundedCornerShape(height / 2)
    Row(
        modifier
            .scale(s)
            .heightIn(min = height)
            .clip(shape)
            .background(c.glass)
            .border(1.dp, c.glassBorder, shape)
            .clickable(interaction, null, role = Role.Button) {
                haptic.performHapticFeedback(HapticFeedbackType.ContextClick)
                onClick()
            }
            .padding(horizontal = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (icon != null) {
            Icon(icon, null, tint = contentColor, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
        }
        Text(text, style = MaterialTheme.typography.labelLarge, color = contentColor, textAlign = TextAlign.Center, modifier = Modifier.padding(vertical = 6.dp))
    }
}

@Composable
fun GlassIconButton(icon: ImageVector, contentDescription: String, onClick: () -> Unit, modifier: Modifier = Modifier, size: Dp = 48.dp) {
    val c = Plexi.colors
    val haptic = LocalHapticFeedback.current
    Box(
        modifier
            .size(size)
            .clip(CircleShape)
            .background(c.glass)
            .border(1.dp, c.glassBorder, CircleShape)
            .clickable(role = Role.Button) {
                haptic.performHapticFeedback(HapticFeedbackType.ContextClick)
                onClick()
            },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription, tint = c.textPrimary, modifier = Modifier.size(size * 0.46f))
    }
}

/* ---------------------------------------------------------------- Segmented control */

data class SegmentOption<T>(val value: T, val label: String, val icon: ImageVector? = null)

@Composable
fun <T> SegmentedControl(
    options: List<SegmentOption<T>>,
    selected: T,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
    height: Dp = 48.dp,
) {
    val c = Plexi.colors
    val haptic = LocalHapticFeedback.current
    val index = options.indexOfFirst { it.value == selected }.coerceAtLeast(0)
    // Grow with the user's font scale (text up to 200%) instead of clipping it.
    val fontScale = LocalDensity.current.fontScale
    val h = height * fontScale.coerceIn(1f, 1.6f)
    val shape = RoundedCornerShape(h / 2)
    BoxWithConstraints(
        modifier
            .height(h)
            .clip(shape)
            .background(if (c.isDark) Color.Black.copy(alpha = 0.28f) else c.backgroundAlt)
            .border(1.dp, c.glassBorder, shape)
            .padding(4.dp),
    ) {
        val segW = maxWidth / options.size
        // Icons only when there is room for icon + label.
        val showIcons = segW >= 110.dp * fontScale.coerceAtLeast(1f)
        val x by animateDpAsState(segW * index, spring(dampingRatio = 0.72f, stiffness = Spring.StiffnessMediumLow), label = "seg")
        Box(
            Modifier
                .offset { androidx.compose.ui.unit.IntOffset(x.roundToPx(), 0) }
                .width(segW)
                .fillMaxHeight()
                .clip(RoundedCornerShape((h - 8.dp) / 2))
                .background(c.accentBrush)
                .background(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.16f), Color.Transparent))),
        )
        Row(Modifier.fillMaxWidth().fillMaxHeight()) {
            options.forEachIndexed { i, opt ->
                val active = i == index
                val fg by animateColorAsState(if (active) Color.White else c.textSecondary, label = "segfg")
                Row(
                    Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .clip(RoundedCornerShape((h - 8.dp) / 2))
                        .clickable(role = Role.Tab) {
                            if (!active) haptic.performHapticFeedback(HapticFeedbackType.SegmentTick)
                            onSelect(opt.value)
                        }
                        .padding(horizontal = 6.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (opt.icon != null && showIcons) {
                        Icon(opt.icon, null, tint = fg, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                    }
                    Text(
                        opt.label, style = MaterialTheme.typography.labelLarge, color = fg,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center,
                    )
                }
            }
        }
    }
}


/* ---------------------------------------------------------------- Chips & badges */

@Composable
fun StatusChip(text: String, color: Color, modifier: Modifier = Modifier, icon: ImageVector? = null) {
    Row(
        modifier
            .clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.14f))
            .border(1.dp, color.copy(alpha = 0.28f), RoundedCornerShape(50))
            .padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, null, tint = color, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(5.dp))
        }
        Text(text, style = MaterialTheme.typography.labelMedium, color = color, maxLines = 1)
    }
}

@Composable
fun ChoiceChips(options: List<String>, selectedIndex: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier) {
    val c = Plexi.colors
    val haptic = LocalHapticFeedback.current
    val fontScale = LocalDensity.current.fontScale
    BoxWithConstraints(modifier) {
        // One equal-width row when every chip fits its label; otherwise wrap onto several rows.
        val gap = 10.dp
        val longest = options.maxOfOrNull { it.length } ?: 1
        val minChip = (longest * 9 + 28).dp * fontScale.coerceAtLeast(1f)
        val fits = maxWidth >= minChip * options.size + gap * (options.size - 1)
        val perRow = if (fits) options.size else ((maxWidth + gap) / (minChip + gap)).toInt().coerceIn(1, options.size)
        val chipW = (maxWidth - gap * (perRow - 1)) / perRow
        @OptIn(ExperimentalLayoutApi::class)
        FlowRow(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(gap),
            verticalArrangement = Arrangement.spacedBy(gap),
            maxItemsInEachRow = perRow,
        ) {
        options.forEachIndexed { i, label ->
            val active = i == selectedIndex
            val shape = RoundedCornerShape(14.dp)
            val bg by animateColorAsState(if (active) c.accentStart.copy(alpha = 0.20f) else c.glass, label = "chipbg")
            Box(
                Modifier
                    .width(chipW)
                    .heightIn(min = 48.dp)
                    .clip(shape)
                    .background(bg)
                    .border(if (active) 1.5.dp else 1.dp, if (active) c.accentBrush else Brush.linearGradient(listOf(c.glassBorder, c.glassBorder)), shape)
                    .clickable(role = Role.RadioButton) {
                        if (!active) haptic.performHapticFeedback(HapticFeedbackType.SegmentTick)
                        onSelect(i)
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label, style = MaterialTheme.typography.labelLarge, color = if (active) c.textPrimary else c.textSecondary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 6.dp, vertical = 8.dp),
                )
            }
        }
        }
    }
}

/* ---------------------------------------------------------------- Rows */

@Composable
fun SettingRow(
    title: String,
    subtitle: String? = null,
    icon: ImageVector? = null,
    modifier: Modifier = Modifier,
    trailing: @Composable RowScope.() -> Unit = {},
) {
    val c = Plexi.colors
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) {
            IconBadge(icon)
            Spacer(Modifier.width(14.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleMedium, color = c.textPrimary)
            if (subtitle != null) Text(subtitle, style = MaterialTheme.typography.bodySmall, color = c.textSecondary)
        }
        trailing()
    }
}

@Composable
fun IconBadge(icon: ImageVector, modifier: Modifier = Modifier, size: Dp = 40.dp, tint: Color? = null) {
    val c = Plexi.colors
    Box(
        modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.32f))
            .background(Brush.linearGradient(listOf(c.accentStart.copy(alpha = 0.22f), c.accentEnd.copy(alpha = 0.14f))))
            .border(1.dp, c.accentStart.copy(alpha = 0.25f), RoundedCornerShape(size * 0.32f)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, null, tint = tint ?: if (c.isDark) Color.White else c.accentStart, modifier = Modifier.size(size * 0.5f))
    }
}

@Composable
fun PlexiSwitch(checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    val c = Plexi.colors
    val haptic = LocalHapticFeedback.current
    Switch(
        checked = checked,
        onCheckedChange = {
            haptic.performHapticFeedback(if (it) HapticFeedbackType.ToggleOn else HapticFeedbackType.ToggleOff)
            onCheckedChange(it)
        },
        colors = SwitchDefaults.colors(
            checkedTrackColor = c.accentStart,
            checkedThumbColor = Color.White,
            checkedBorderColor = Color.Transparent,
            uncheckedTrackColor = if (c.isDark) Color.White.copy(alpha = 0.08f) else c.backgroundAlt,
            uncheckedBorderColor = c.glassBorderHighlight.copy(alpha = 0.3f),
            uncheckedThumbColor = c.textTertiary,
        ),
    )
}

@Composable
fun Hairline(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(1.dp).background(Plexi.colors.glassBorder))
}

@Composable
fun ProvideContentColor(color: Color, content: @Composable () -> Unit) =
    CompositionLocalProvider(LocalContentColor provides color, content = content)

/** Gradient-masked icon. */
@Composable
fun GradientIcon(icon: ImageVector, modifier: Modifier = Modifier, brush: Brush = Plexi.colors.accentBrush) {
    Icon(
        icon, null,
        modifier = modifier
            .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
            .drawWithCache { onDrawWithContent { drawContent(); drawRect(brush, blendMode = BlendMode.SrcAtop) } },
        tint = Color.White,
    )
}

@Composable
fun VerticalSpace(h: Dp) = Spacer(Modifier.height(h))

/* ---------------------------------------------------------------- Brand mark */

/** App logo: gradient squircle with a tablet and a display glyph (mirrors the launcher icon). */
@Composable
fun BrandMark(modifier: Modifier = Modifier) {
    val c = Plexi.colors
    androidx.compose.foundation.Canvas(modifier) {
        val s = size.minDimension
        val cr = androidx.compose.ui.geometry.CornerRadius(s * 0.3f)
        drawRoundRect(Brush.linearGradient(listOf(c.accentStart, c.accentEnd), androidx.compose.ui.geometry.Offset.Zero, androidx.compose.ui.geometry.Offset(s, s)), cornerRadius = cr)
        drawRoundRect(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.25f), Color.Transparent), 0f, s * 0.6f), cornerRadius = cr)
        val stroke = androidx.compose.ui.graphics.drawscope.Stroke(s * 0.075f)
        // back display
        drawRoundRect(Color.White.copy(alpha = 0.55f), androidx.compose.ui.geometry.Offset(s * 0.18f, s * 0.24f), androidx.compose.ui.geometry.Size(s * 0.44f, s * 0.32f), androidx.compose.ui.geometry.CornerRadius(s * 0.05f), style = stroke)
        // front tablet
        drawRoundRect(Color.White, androidx.compose.ui.geometry.Offset(s * 0.40f, s * 0.42f), androidx.compose.ui.geometry.Size(s * 0.42f, s * 0.32f), androidx.compose.ui.geometry.CornerRadius(s * 0.06f))
        drawRoundRect(Brush.linearGradient(listOf(c.accentStart, c.accentEnd)), androidx.compose.ui.geometry.Offset(s * 0.455f, s * 0.475f), androidx.compose.ui.geometry.Size(s * 0.31f, s * 0.21f), androidx.compose.ui.geometry.CornerRadius(s * 0.025f))
    }
}
