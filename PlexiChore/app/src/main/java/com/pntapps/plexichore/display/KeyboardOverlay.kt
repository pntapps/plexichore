package com.pntapps.plexichore.display

import android.view.HapticFeedbackConstants
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraintsScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.pntapps.plexichore.ui.data.KeyboardBubblePos
import kotlin.math.roundToInt

/** What the overlay shows for the keyboard. */
internal data class KeyboardOverlayState(
    /** Keyboard requested open: shows the extra-keys row and marks the buttons selected. */
    val open: Boolean = false,
    /** Floating keyboard button (Settings › Keyboard button on screen). */
    val showBubble: Boolean = false,
    val armed: Set<StickyModifier> = emptySet(),
    val locked: Set<StickyModifier> = emptySet(),
    val bubbleLandscape: KeyboardBubblePos = KeyboardBubblePos(),
    val bubblePortrait: KeyboardBubblePos = KeyboardBubblePos(),
    /** No IME insets before API 30: dock the keys row at the top instead of above the IME. */
    val keysAtTop: Boolean = false,
)

internal interface KeyboardActions {
    fun toggle()
    fun hide()
    /** One key press; [consume] false while auto-repeating (one-shot modifiers stay armed until [release]). */
    fun press(keyCode: Int, consume: Boolean)
    fun release()
    fun toggleModifier(m: StickyModifier)
    fun moveBubble(landscape: Boolean, pos: KeyboardBubblePos)

    object None : KeyboardActions {
        override fun toggle() = Unit
        override fun hide() = Unit
        override fun press(keyCode: Int, consume: Boolean) = Unit
        override fun release() = Unit
        override fun toggleModifier(m: StickyModifier) = Unit
        override fun moveBubble(landscape: Boolean, pos: KeyboardBubblePos) = Unit
    }
}

private val BubbleSize = 52.dp
private val BubbleMargin = 12.dp
private val KeyRowHeight = 64.dp // 48dp keys + padding

/** Draggable, edge-snapping keyboard button. Lives in the overlay's (inset-padded) box. */
@Composable
internal fun BoxWithConstraintsScope.KeyboardBubble(
    state: KeyboardOverlayState,
    actions: KeyboardActions,
    onRegion: (String, Rect?) -> Unit,
) {
    val landscape = maxWidth > maxHeight
    val saved = if (landscape) state.bubbleLandscape else state.bubblePortrait
    val density = LocalDensity.current
    val view = LocalView.current
    val wPx = with(density) { maxWidth.toPx() }
    val hPx = with(density) { maxHeight.toPx() }
    val sizePx = with(density) { BubbleSize.toPx() }
    val marginPx = with(density) { BubbleMargin.toPx() }
    // Above the keys row while the keyboard is open (the box is already padded by the IME).
    val bottomReserve = if (state.open && !state.keysAtTop) with(density) { KeyRowHeight.toPx() + 8.dp.toPx() } else 0f
    val freeH = (hPx - sizePx - 2 * marginPx - bottomReserve).coerceAtLeast(0f)
    val baseX = if (saved.left) marginPx else wPx - sizePx - marginPx
    val baseY = marginPx + saved.yFraction * freeH

    var drag by remember { mutableStateOf<Offset?>(null) }
    var pressed by remember { mutableStateOf(false) }
    val latestSaved by rememberUpdatedState(saved)
    val latestGeometry by rememberUpdatedState(floatArrayOf(wPx, freeH, sizePx, marginPx))
    val x = (baseX + (drag?.x ?: 0f)).coerceIn(0f, (wPx - sizePx).coerceAtLeast(0f))
    val y = (baseY + (drag?.y ?: 0f)).coerceIn(0f, (hPx - sizePx).coerceAtLeast(0f))
    val label = if (state.open) "Hide keyboard" else "Show keyboard"

    DisposableRegion("kbBubble", onRegion)
    val scheme = MaterialTheme.colorScheme
    Surface(
        shape = CircleShape,
        color = if (state.open) scheme.primary else scheme.surfaceContainerHigh,
        contentColor = if (state.open) scheme.onPrimary else scheme.onSurface,
        shadowElevation = 6.dp,
        modifier = Modifier
            .offset { IntOffset(x.roundToInt(), y.roundToInt()) }
            .size(BubbleSize)
            .alpha(if (state.open || pressed || drag != null) 1f else 0.6f)
            .onGloballyPositioned { onRegion("kbBubble", it.boundsInRoot()) }
            .semantics {
                contentDescription = label
                role = Role.Button
                onClick(label) { actions.toggle(); true }
            }
            .pointerInput(Unit) {
                detectTapGestures(
                    onPress = {
                        pressed = true
                        tryAwaitRelease()
                        pressed = false
                    },
                    onTap = {
                        view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                        actions.toggle()
                    },
                )
            }
            .pointerInput(landscape) {
                detectDragGestures(
                    onDragStart = { drag = Offset.Zero },
                    onDrag = { change, amount ->
                        change.consume()
                        drag = (drag ?: Offset.Zero) + amount
                    },
                    onDragEnd = {
                        val g = latestGeometry
                        val w = g[0]; val free = g[1]; val size = g[2]; val margin = g[3]
                        val s = latestSaved
                        val d = drag ?: Offset.Zero
                        val curX = (if (s.left) margin else w - size - margin) + d.x
                        val curY = margin + s.yFraction * free + d.y
                        val pos = KeyboardBubblePos(
                            left = curX + size / 2 < w / 2,
                            yFraction = if (free > 0f) ((curY - margin) / free).coerceIn(0f, 1f) else s.yFraction,
                        )
                        drag = null
                        actions.moveBubble(landscape, pos)
                    },
                    onDragCancel = { drag = null },
                )
            },
    ) {
        Box(contentAlignment = Alignment.Center) {
            Icon(OverlayIcons.Keyboard, contentDescription = null, modifier = Modifier.size(26.dp))
        }
    }
}

/** Esc Tab Ctrl Alt ⌘/Win ← ↑ ↓ → Del ⌄ — docked above the IME, scrolls sideways on narrow screens. */
@Composable
internal fun ExtraKeysRow(
    state: KeyboardOverlayState,
    hostOs: String,
    actions: KeyboardActions,
    modifier: Modifier = Modifier,
) {
    val scheme = MaterialTheme.colorScheme
    val mac = hostOs.equals("macos", ignoreCase = true)
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(20.dp),
        color = scheme.surfaceContainerHigh.copy(alpha = 0.92f),
        contentColor = scheme.onSurface,
        tonalElevation = 6.dp,
        shadowElevation = 8.dp,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            modifier = Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp, vertical = 8.dp),
        ) {
            KeyButton("Esc", "Escape", onPress = { actions.press(KeyCodes.ESCAPE, it) }, onRelease = actions::release)
            KeyButton("Tab", "Tab", onPress = { actions.press(KeyCodes.TAB, it) }, onRelease = actions::release)
            ModifierKey("Ctrl", if (mac) "Control" else "Ctrl", StickyModifier.CTRL, state, actions)
            ModifierKey(if (mac) "⌥" else "Alt", if (mac) "Option" else "Alt", StickyModifier.ALT, state, actions)
            ModifierKey(if (mac) "⌘" else "Win", if (mac) "Command" else "Windows key", StickyModifier.META, state, actions)
            KeyButton(null, "Left arrow", icon = OverlayIcons.ArrowLeft, repeat = true, onPress = { actions.press(KeyCodes.DPAD_LEFT, it) }, onRelease = actions::release)
            KeyButton(null, "Up arrow", icon = OverlayIcons.ArrowUp, repeat = true, onPress = { actions.press(KeyCodes.DPAD_UP, it) }, onRelease = actions::release)
            KeyButton(null, "Down arrow", icon = OverlayIcons.ArrowDown, repeat = true, onPress = { actions.press(KeyCodes.DPAD_DOWN, it) }, onRelease = actions::release)
            KeyButton(null, "Right arrow", icon = OverlayIcons.ArrowRight, repeat = true, onPress = { actions.press(KeyCodes.DPAD_RIGHT, it) }, onRelease = actions::release)
            KeyButton("Del", "Forward delete", repeat = true, onPress = { actions.press(KeyCodes.FORWARD_DEL, it) }, onRelease = actions::release)
            KeyButton(
                label = null, description = "Hide keyboard", icon = OverlayIcons.KeyboardHide,
                onPress = { if (it) actions.hide() }, onRelease = {},
            )
        }
    }
}

@Composable
private fun ModifierKey(label: String, name: String, m: StickyModifier, state: KeyboardOverlayState, actions: KeyboardActions) {
    val mode = when (m) {
        in state.locked -> KeyLook.Locked
        in state.armed -> KeyLook.Armed
        else -> KeyLook.Normal
    }
    KeyButton(
        label = label,
        description = name,
        look = mode,
        stateText = when (mode) {
            KeyLook.Locked -> "locked"
            KeyLook.Armed -> "on for the next key"
            KeyLook.Normal -> "off"
        },
        onPress = { if (it) actions.toggleModifier(m) },
        onRelease = {},
    )
}

private enum class KeyLook { Normal, Armed, Locked }

/**
 * One key: fires on tap; with [repeat], a long press fires at once and then repeats (400 ms, then every
 * 50 ms) until released. Plain pointer handling, so it never takes focus from the IME's editor.
 * [onPress] gets `consume` = false while repeating.
 */
@Composable
private fun KeyButton(
    label: String?,
    description: String,
    onPress: (consume: Boolean) -> Unit,
    onRelease: () -> Unit,
    repeat: Boolean = false,
    look: KeyLook = KeyLook.Normal,
    stateText: String? = null,
    icon: ImageVector? = null,
) {
    val scheme = MaterialTheme.colorScheme
    val view = LocalView.current
    var pressed by remember { mutableStateOf(false) }
    val press by rememberUpdatedState(onPress)
    val release by rememberUpdatedState(onRelease)
    val bg = when {
        look == KeyLook.Locked -> scheme.primary
        look == KeyLook.Armed -> scheme.primary.copy(alpha = 0.22f)
        pressed -> scheme.onSurface.copy(alpha = 0.16f)
        else -> scheme.onSurface.copy(alpha = 0.06f)
    }
    val fg = if (look == KeyLook.Locked) scheme.onPrimary else if (look == KeyLook.Armed) scheme.primary else scheme.onSurface
    val shape = RoundedCornerShape(12.dp)
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .heightIn(min = 48.dp)
            .widthIn(min = 52.dp)
            .background(bg, shape)
            .then(if (look == KeyLook.Armed) Modifier.border(BorderStroke(2.dp, scheme.primary), shape) else Modifier)
            .semantics {
                contentDescription = description
                role = Role.Button
                if (stateText != null) stateDescription = stateText
                onClick(description) { press(true); release(); true }
            }
            .pointerInput(repeat) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    pressed = true
                    var cancelled = false
                    val ended = withTimeoutOrNull(REPEAT_DELAY_MS) {
                        if (waitForUpOrCancellation() == null) cancelled = true
                        true
                    }
                    if (ended == true) {
                        if (!cancelled) {
                            view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                            press(true)
                        }
                    } else if (!repeat) {
                        if (waitForUpOrCancellation() != null) {
                            view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                            press(true)
                        }
                    } else {
                        // Long press: repeat until the finger lifts (or slides off / scrolls).
                        while (true) {
                            view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                            press(false)
                            var done = false
                            withTimeoutOrNull(REPEAT_INTERVAL_MS) {
                                waitForUpOrCancellation()
                                done = true
                            }
                            if (done) break
                        }
                        release()
                    }
                    pressed = false
                }
            }
            .padding(horizontal = 12.dp),
    ) {
        if (icon != null) Icon(icon, contentDescription = null, tint = fg, modifier = Modifier.size(24.dp))
        else Text(
            label.orEmpty(),
            color = fg,
            // Single glyphs (arrows, ⌘, ⌥) render small in most fonts: give them more size.
            style = if (label.orEmpty().length == 1) MaterialTheme.typography.titleLarge else MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            softWrap = false,
        )
    }
}

private const val REPEAT_DELAY_MS = 400L
private const val REPEAT_INTERVAL_MS = 50L

@Composable
private fun DisposableRegion(key: String, onRegion: (String, Rect?) -> Unit) {
    androidx.compose.runtime.DisposableEffect(key) { onDispose { onRegion(key, null) } }
}
