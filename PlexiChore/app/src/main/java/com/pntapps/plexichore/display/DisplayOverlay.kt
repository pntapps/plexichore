package com.pntapps.plexichore.display

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.tappableElement
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pntapps.plexichore.core.ConnectionState
import com.pntapps.plexichore.core.DisplayMode
import com.pntapps.plexichore.core.StreamSettings
import com.pntapps.plexichore.core.StreamStats
import com.pntapps.plexichore.core.TouchMode
import java.util.Locale

/** Everything drawn above the video. Interactive bounds are reported via [onRegion]. */
@Composable
internal fun DisplayOverlay(
    state: ConnectionState,
    stats: StreamStats,
    settings: StreamSettings,
    controlsVisible: Boolean,
    showHint: Boolean,
    hasStreamed: Boolean,
    onDisconnect: () -> Unit,
    onToggleStats: () -> Unit,
    onCycleTouchMode: () -> Unit,
    onRegion: (key: String, bounds: Rect?) -> Unit,
    onCycleScale: () -> Unit = {},
    /** Tablet held portrait while the host streams landscape (no portrait mode on the PC). */
    orientationHint: Boolean = false,
) {
    val streaming = state as? ConnectionState.Streaming
    // Safe area: in true immersive mode the hidden bars report 0, so this only keeps controls clear
    // of the camera cutout, and of status/caption/task bars in split-screen, freeform and DeX windows.
    BoxWithConstraints(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing.union(WindowInsets.tappableElement))) {
        val fontScale = LocalDensity.current.fontScale
        val compact = maxWidth < 560.dp || fontScale > 1.3f
        val pillMax = maxWidth - 24.dp
        AnimatedVisibility(
            visible = streaming != null && settings.showStatsOverlay,
            enter = fadeIn(),
            exit = fadeOut(),
            modifier = Modifier.align(Alignment.TopStart).padding(start = 16.dp, top = if (controlsVisible) 76.dp else 16.dp),
        ) {
            if (streaming != null) StatsCard(streaming, stats)
        }

        AnimatedVisibility(
            visible = controlsVisible && streaming != null,
            enter = fadeIn() + slideInVertically { -it },
            exit = fadeOut() + slideOutVertically { -it },
            modifier = Modifier.align(Alignment.TopCenter).padding(top = 14.dp),
        ) {
            ReportRegion("pill", onRegion)
            ControlPill(
                settings = settings,
                hostName = streaming?.config?.hostName.orEmpty(),
                onDisconnect = onDisconnect,
                onToggleStats = onToggleStats,
                onCycleTouchMode = onCycleTouchMode,
                modifier = Modifier.widthIn(max = pillMax).onGloballyPositioned { onRegion("pill", it.boundsInRoot()) },
                showSize = streaming != null && streaming.config.mode != DisplayMode.MIRROR,
                appliedScale = streaming?.config?.scalePercent ?: 0,
                onCycleScale = onCycleScale,
                iconOnly = compact,
                showHost = maxWidth >= 420.dp,
            )
        }

        AnimatedVisibility(
            visible = streaming != null && !controlsVisible && (showHint || orientationHint),
            enter = fadeIn(),
            exit = fadeOut(),
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 24.dp, start = 16.dp, end = 16.dp),
        ) {
            Surface(
                shape = RoundedCornerShape(24.dp),
                color = MaterialTheme.colorScheme.inverseSurface.copy(alpha = 0.82f),
                contentColor = MaterialTheme.colorScheme.inverseOnSurface,
            ) {
                Text(
                    if (orientationHint) "Rotate the tablet to landscape for a full-screen picture — this computer has no portrait display mode"
                    else "Swipe down from the top edge or tap with three fingers for controls",
                    style = MaterialTheme.typography.labelLarge,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
                )
            }
        }

        if (streaming == null) StatusCard(state, hasStreamed, onCancel = onDisconnect, modifier = Modifier.align(Alignment.Center).padding(16.dp))
    }
}

/** Clears a region when its composable leaves the composition. */
@Composable
private fun ReportRegion(key: String, onRegion: (String, Rect?) -> Unit) {
    DisposableEffect(key) { onDispose { onRegion(key, null) } }
}

@Composable
private fun ControlPill(
    settings: StreamSettings,
    hostName: String,
    onDisconnect: () -> Unit,
    onToggleStats: () -> Unit,
    onCycleTouchMode: () -> Unit,
    modifier: Modifier = Modifier,
    showSize: Boolean = false,
    appliedScale: Int = 0,
    onCycleScale: () -> Unit = {},
    /** Small windows / large font: buttons become 48dp icons (labels stay as content descriptions). */
    iconOnly: Boolean = false,
    showHost: Boolean = true,
) {
    val scheme = MaterialTheme.colorScheme
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(50),
        color = scheme.surfaceContainerHigh.copy(alpha = 0.9f),
        contentColor = scheme.onSurface,
        tonalElevation = 6.dp,
        shadowElevation = 8.dp,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
        ) {
            if (showHost && hostName.isNotBlank()) {
                Text(
                    hostName,
                    style = MaterialTheme.typography.labelLarge,
                    color = scheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    // Shrinks first, so the buttons (and Disconnect, always last) never leave the screen.
                    modifier = Modifier.weight(1f, fill = false).padding(start = 10.dp, end = 6.dp).widthIn(max = 220.dp),
                )
            }
            val touchLabel = when (settings.touchMode) {
                TouchMode.TOUCH -> "Touch"
                TouchMode.MOUSE -> "Mouse"
                TouchMode.NONE -> "Input off"
            }
            PillButton(
                icon = when (settings.touchMode) {
                    TouchMode.TOUCH -> OverlayIcons.Touch
                    TouchMode.MOUSE -> OverlayIcons.Mouse
                    TouchMode.NONE -> OverlayIcons.Block
                },
                label = touchLabel,
                selected = false,
                onClick = onCycleTouchMode,
                iconOnly = iconOnly,
            )
            if (showSize) {
                // host display scale of the virtual monitor (extend / primary); cycles Auto → 150% … 250% → Auto
                val sizeLabel = if (settings.scalePercent <= 0) {
                    if (appliedScale > 0) "Auto $appliedScale%" else "Auto"
                } else "${settings.scalePercent}%"
                PillButton(
                    icon = OverlayIcons.Size,
                    label = sizeLabel,
                    selected = false,
                    onClick = onCycleScale,
                    iconOnly = iconOnly,
                    contentDescription = "Display size $sizeLabel",
                )
            }
            PillButton(
                icon = OverlayIcons.Stats,
                label = "Stats",
                selected = settings.showStatsOverlay,
                onClick = onToggleStats,
                iconOnly = iconOnly,
            )
            IconButton(
                onClick = onDisconnect,
                colors = IconButtonDefaults.iconButtonColors(
                    containerColor = scheme.error.copy(alpha = 0.16f),
                    contentColor = scheme.error,
                ),
            ) {
                Icon(OverlayIcons.Close, contentDescription = "Disconnect")
            }
        }
    }
}

@Composable
private fun PillButton(
    icon: ImageVector,
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    iconOnly: Boolean = false,
    contentDescription: String = label,
) {
    val scheme = MaterialTheme.colorScheme
    if (iconOnly) {
        IconButton(
            onClick = onClick,
            colors = IconButtonDefaults.iconButtonColors(
                containerColor = if (selected) scheme.primary.copy(alpha = 0.18f) else Color.Transparent,
                contentColor = if (selected) scheme.primary else scheme.onSurface,
            ),
        ) {
            Icon(icon, contentDescription = contentDescription, modifier = Modifier.size(22.dp))
        }
        return
    }
    TextButton(
        onClick = onClick,
        shape = RoundedCornerShape(50),
        colors = androidx.compose.material3.ButtonDefaults.textButtonColors(
            containerColor = if (selected) scheme.primary.copy(alpha = 0.18f) else Color.Transparent,
            contentColor = if (selected) scheme.primary else scheme.onSurface,
        ),
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(6.dp))
        Text(label, style = MaterialTheme.typography.labelLarge, maxLines = 1, softWrap = false)
    }
}

@Composable
private fun StatsCard(streaming: ConnectionState.Streaming, stats: StreamStats) {
    val c = streaming.config
    val mbps = stats.bitrateKbps / 1000f
    val lines = listOf(
        "%.0f fps".format(Locale.US, stats.fps),
        "%.0f ms rtt".format(Locale.US, stats.rttMs),
        "%.1f Mbps".format(Locale.US, mbps),
        "${c.width}×${c.height} ${c.codec.uppercase()}",
        "decode %.1f ms".format(Locale.US, stats.decodeMs),
        "dropped ${stats.droppedFrames}",
    )
    Column(
        modifier = Modifier
            .background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(12.dp))
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        lines.forEach {
            Text(it, color = Color.White, fontFamily = FontFamily.Monospace, fontSize = 12.sp, lineHeight = 16.sp)
        }
    }
}

@Composable
private fun StatusCard(state: ConnectionState, reconnecting: Boolean, onCancel: () -> Unit, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    Surface(
        modifier = modifier.widthIn(min = 320.dp, max = 460.dp),
        shape = RoundedCornerShape(24.dp),
        color = scheme.surfaceContainerHigh.copy(alpha = 0.94f),
        contentColor = scheme.onSurface,
        tonalElevation = 6.dp,
        shadowElevation = 12.dp,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.padding(horizontal = 28.dp, vertical = 24.dp),
        ) {
            when (state) {
                is ConnectionState.AwaitingApproval -> {
                    Text("Approve on ${state.host.name}", style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
                    Spacer(Modifier.height(12.dp))
                    Text(
                        state.code.ifBlank { "····" },
                        style = MaterialTheme.typography.displaySmall,
                        fontWeight = FontWeight.SemiBold,
                        letterSpacing = 8.sp,
                        color = scheme.primary,
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Check that this code matches the one shown on the computer.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = scheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                }
                is ConnectionState.Connecting -> {
                    CircularProgressIndicator(Modifier.size(36.dp), strokeWidth = 3.dp)
                    Spacer(Modifier.height(16.dp))
                    Text(if (reconnecting) "Reconnecting to ${state.host.name}…" else "Connecting to ${state.host.name}…", style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
                }
                else -> Text("Disconnected", style = MaterialTheme.typography.titleMedium)
            }
            Spacer(Modifier.height(16.dp))
            TextButton(onClick = onCancel) { Text("Cancel") }
        }
    }
}

/** Minimal Material-style glyphs, so the overlay needs no icon library. */
internal object OverlayIcons {
    val Close = icon("Close", "M19,6.41L17.59,5 12,10.59 6.41,5 5,6.41 10.59,12 5,17.59 6.41,19 12,13.41 17.59,19 19,17.59 13.41,12z")
    val Stats = icon("Stats", "M10,20h4V4h-4v16zm-6,0h4v-8H4v8zM16,9v11h4V9h-4z")
    val Size = icon("Size", "M9,4v3h5v12h3V7h5V4H9zM3,12h3v7h3v-7h3V9H3v3z")
    val Mouse = icon(
        "Mouse",
        "M13,1.07V9h7c0,-4.08 -3.05,-7.44 -7,-7.93zM4,15c0,4.42 3.58,8 8,8s8,-3.58 8,-8v-4H4v4zm7,-13.93C7.05,1.56 4,4.92 4,9h7V1.07z",
    )
    val Touch = icon(
        "Touch",
        "M9,11.24V7.5C9,6.12 10.12,5 11.5,5S14,6.12 14,7.5v3.74c1.21,-0.81 2,-2.18 2,-3.74C16,5.01 13.99,3 11.5,3S7,5.01 7,7.5" +
            "c0,1.56 0.79,2.93 2,3.74zM18.84,15.87l-4.54,-2.26c-0.17,-0.07 -0.35,-0.11 -0.54,-0.11H13v-6C13,6.67 12.33,6 11.5,6" +
            "S10,6.67 10,7.5v10.74l-3.43,-0.72c-0.08,-0.01 -0.15,-0.03 -0.24,-0.03 -0.31,0 -0.59,0.13 -0.79,0.33l-0.79,0.8 4.94,4.94" +
            "c0.27,0.27 0.65,0.44 1.06,0.44h6.79c0.75,0 1.33,-0.55 1.44,-1.28l0.75,-5.27c0.01,-0.07 0.02,-0.14 0.02,-0.2 0,-0.62 -0.38,-1.16 -0.91,-1.38z",
    )
    val Block = icon(
        "Block",
        "M12,2C6.48,2 2,6.48 2,12s4.48,10 10,10 10,-4.48 10,-10S17.52,2 12,2zM4,12c0,-4.42 3.58,-8 8,-8 1.85,0 3.55,0.63 4.9,1.69" +
            "L5.69,16.9C4.63,15.55 4,13.85 4,12zm8,8c-1.85,0 -3.55,-0.63 -4.9,-1.69L18.31,7.1C19.37,8.45 20,10.15 20,12c0,4.42 -3.58,8 -8,8z",
    )

    private fun icon(name: String, path: String): ImageVector =
        ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f)
            .addPath(pathData = addPathNodes(path), fill = SolidColor(Color.Black))
            .build()
}
