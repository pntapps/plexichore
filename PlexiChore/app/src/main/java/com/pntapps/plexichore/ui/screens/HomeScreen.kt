package com.pntapps.plexichore.ui.screens

import android.content.ComponentName
import android.content.Intent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.border
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.ui.unit.sp
import com.pntapps.plexichore.ui.components.heroCaption
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.Balance
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.DesktopWindows
import androidx.compose.material.icons.rounded.Diamond
import androidx.compose.material.icons.automirrored.rounded.HelpOutline
import androidx.compose.material.icons.rounded.Lan
import androidx.compose.material.icons.rounded.LaptopMac
import androidx.compose.material.icons.rounded.LaptopWindows
import androidx.compose.material.icons.rounded.LinkOff
import androidx.compose.material.icons.rounded.Monitor
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.automirrored.rounded.ScreenShare
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Usb
import androidx.compose.material.icons.rounded.ViewQuilt
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material.icons.rounded.WifiFind
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import com.pntapps.plexichore.ui.HostGroup
import com.pntapps.plexichore.ui.components.LocalNetworkPermissionState
import com.pntapps.plexichore.ui.components.rememberLocalNetworkPermission
import com.pntapps.plexichore.ui.components.plexiSafeTopAndSides
import com.pntapps.plexichore.ui.components.safeBottomPadding
import androidx.lifecycle.compose.LifecycleStartEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pntapps.plexichore.core.ConnectionState
import com.pntapps.plexichore.core.DiscoveredHost
import com.pntapps.plexichore.core.DisplayMode
import com.pntapps.plexichore.core.HostDiscovery
import com.pntapps.plexichore.core.Quality
import com.pntapps.plexichore.core.Transport
import com.pntapps.plexichore.ui.MainViewModel
import com.pntapps.plexichore.ui.components.GhostButton
import com.pntapps.plexichore.ui.components.GlassCard
import com.pntapps.plexichore.ui.components.GlassIconButton
import com.pntapps.plexichore.ui.components.GradientButton
import com.pntapps.plexichore.ui.components.HeroIllustration
import com.pntapps.plexichore.ui.components.IconBadge
import com.pntapps.plexichore.ui.components.RadarScanner
import com.pntapps.plexichore.ui.components.SectionLabel
import com.pntapps.plexichore.ui.components.SegmentOption
import com.pntapps.plexichore.ui.components.SegmentedControl
import com.pntapps.plexichore.ui.components.StatusChip
import com.pntapps.plexichore.ui.navigation.LocalAdaptive
import com.pntapps.plexichore.ui.theme.Plexi
import com.pntapps.plexichore.ui.components.BrandMark
import com.pntapps.plexichore.ui.components.displayModeOptions
import com.pntapps.plexichore.ui.components.description
import com.pntapps.plexichore.ui.components.sessionLabel

@Composable
fun HomeScreen(vm: MainViewModel, onOpenSettings: () -> Unit, onOpenHelp: () -> Unit) {
    val prefs by vm.prefs.collectAsStateWithLifecycle()
    val groups by vm.hostGroups.collectAsStateWithLifecycle()
    val state by vm.state.collectAsStateWithLifecycle()
    val adaptive = LocalAdaptive.current
    var showIpDialog by rememberSaveable { mutableStateOf(false) }
    val lan = rememberLocalNetworkPermission()

    // Discover only while Home is on screen and the app is started.
    LifecycleStartEffect(Unit) {
        vm.startDiscovery()
        onStopOrDispose { vm.stopDiscovery() }
    }

    val stream = prefs?.stream ?: return
    val streaming = state as? ConnectionState.Streaming
    val bottom = safeBottomPadding() + 24.dp

    val controls: @Composable ColumnScope.() -> Unit = {
        QuickControls(
            mode = stream.mode, onMode = vm::setMode,
            quality = stream.quality, onQuality = vm::setQuality,
        )
    }

    Column(Modifier.fillMaxSize().plexiSafeTopAndSides()) {
        TopBar(onOpenHelp, onOpenSettings)
        if (adaptive.twoPane) {
            Row(Modifier.fillMaxSize().padding(horizontal = 28.dp), horizontalArrangement = Arrangement.spacedBy(28.dp)) {
                LeftPane(Modifier.weight(0.43f).fillMaxHeight(), bottom, stream.mode, controls)
                LazyColumn(
                    Modifier.weight(0.57f).fillMaxHeight(),
                    contentPadding = PaddingValues(bottom = bottom),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    hostsSection(groups, streaming, vm, onOpenHelp, onManual = { showIpDialog = true }, lan)
                }
            }
        } else {
            val side = if (adaptive.compactHeight) 20.dp else 24.dp
            LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(start = side, end = side, bottom = bottom),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                item { HeroCard(stream.mode) }
                item { Column(verticalArrangement = Arrangement.spacedBy(14.dp)) { controls() } }
                item { Spacer(Modifier.height(6.dp)) }
                hostsSection(groups, streaming, vm, onOpenHelp, onManual = { showIpDialog = true }, lan)
            }
        }
    }

    if (showIpDialog) {
        ConnectByIpDialog(
            initial = prefs?.lastManualIp.orEmpty(),
            onDismiss = { showIpDialog = false },
            onConnect = { showIpDialog = false; vm.connectManual(it) },
        )
    }
}

/**
 * Left column of the two-pane layout. With enough height it fits without scrolling (the hero
 * illustration absorbs whatever height is left, so nothing sits under the taskbar at rest);
 * otherwise (short windows, large font) it scrolls.
 */
@Composable
private fun LeftPane(modifier: Modifier, bottom: Dp, mode: DisplayMode, controls: @Composable ColumnScope.() -> Unit) {
    val fontScale = LocalDensity.current.fontScale
    BoxWithConstraints(modifier) {
        if (maxHeight >= 600.dp && fontScale <= 1.3f) {
            Column(Modifier.fillMaxSize().padding(bottom = bottom), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                HeroCard(mode, Modifier.weight(1f, fill = false), flexibleArt = true)
                controls()
            }
        } else {
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = bottom),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                HeroCard(mode)
                controls()
            }
        }
    }
}

/* ------------------------------------------------------------------ top bar */

@Composable
private fun TopBar(onOpenHelp: () -> Unit, onOpenSettings: () -> Unit) {
    val c = Plexi.colors
    Row(
        Modifier.fillMaxWidth().padding(start = 28.dp, end = 24.dp, top = 14.dp, bottom = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BrandMark(Modifier.size(38.dp))
        Spacer(Modifier.width(12.dp))
        Text(
            "PlexiChore", style = MaterialTheme.typography.titleLarge, color = c.textPrimary,
            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
        )
        GlassIconButton(Icons.AutoMirrored.Rounded.HelpOutline, "Setup guide", onOpenHelp)
        Spacer(Modifier.width(10.dp))
        GlassIconButton(Icons.Rounded.Settings, "Settings", onOpenSettings)
    }
}

/* ------------------------------------------------------------------ hero */

@Composable
private fun HeroCard(mode: DisplayMode, modifier: Modifier = Modifier, flexibleArt: Boolean = false) {
    val c = Plexi.colors
    val adaptive = LocalAdaptive.current
    GlassCard(modifier.fillMaxWidth(), contentPadding = PaddingValues(0.dp)) {
        BoxWithConstraints(
            Modifier.fillMaxWidth().then(if (flexibleArt) Modifier.weight(1f, fill = false) else Modifier).padding(top = 22.dp),
            contentAlignment = Alignment.Center,
        ) {
            // Art width: a share of the card, capped by the height that is actually available.
            val ratio = 100f / 62f
            val byWidth = maxWidth * (if (adaptive.twoPane) 0.74f else 0.68f)
            // Phones in landscape: no art at all, the hosts must be reachable without scrolling a whole screen.
            val cap = when {
                adaptive.compactHeight && !adaptive.twoPane -> 0.dp
                adaptive.compactHeight -> 150.dp
                else -> 300.dp
            } * ratio
            val byHeight = if (maxHeight == Dp.Infinity) cap else maxHeight * ratio
            val w = minOf(byWidth, cap, byHeight)
            if (w >= 80.dp) {
                Box(Modifier.width(w)) {
                    HeroIllustration(Modifier.fillMaxWidth(), mode = mode)
                    // The art leaves its bottom ~18% free (below the devices): the caption sits there.
                    if (w >= 220.dp) HeroCaption(mode, Modifier.align(Alignment.BottomCenter))
                }
            }
        }
        Column(Modifier.padding(start = 26.dp, end = 26.dp, bottom = 26.dp, top = 4.dp)) {
            Text(
                buildAnnotatedString {
                    append("Your tablet,\n")
                    withStyle(SpanStyle(brush = Brush.linearGradient(listOf(c.accentStart, c.accentEnd)))) { append("your next screen.") }
                },
                style = MaterialTheme.typography.headlineMedium,
                color = c.textPrimary,
            )
            Spacer(Modifier.height(10.dp))
            Text(
                "Extend, mirror, or make it your main screen — for Windows PC or Mac over USB or Wi-Fi. Touch and pen included.",
                style = MaterialTheme.typography.bodyMedium,
                color = c.textSecondary,
            )
        }
    }
}

/** What the hero animation is showing for [mode]; crossfades with the selection. */
@Composable
private fun HeroCaption(mode: DisplayMode, modifier: Modifier = Modifier) {
    val c = Plexi.colors
    AnimatedContent(
        mode, modifier,
        transitionSpec = { fadeIn(tween(320, delayMillis = 120)) togetherWith fadeOut(tween(180)) using SizeTransform(clip = false) },
        contentAlignment = Alignment.Center,
        label = "heroCaption",
    ) { m ->
        Row(
            Modifier
                .clip(RoundedCornerShape(50))
                .background(c.glass)
                .border(1.dp, c.glassBorder, RoundedCornerShape(50))
                .padding(horizontal = 12.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            displayModeOptions.first { it.value == m }.icon?.let {
                Icon(it, null, tint = c.accentEnd, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(7.dp))
            }
            val style = MaterialTheme.typography.labelMedium
            Text(
                m.heroCaption, style = style, color = c.textSecondary, maxLines = 1, softWrap = false,
                autoSize = TextAutoSize.StepBased(minFontSize = 9.sp, maxFontSize = style.fontSize, stepSize = 0.5.sp),
            )
        }
    }
}

/* ------------------------------------------------------------------ quick controls */

@Composable
private fun QuickControls(mode: DisplayMode, onMode: (DisplayMode) -> Unit, quality: Quality, onQuality: (Quality) -> Unit) {
    val c = Plexi.colors
    GlassCard(Modifier.fillMaxWidth(), contentPadding = PaddingValues(22.dp)) {
        SectionLabel("Display mode")
        Spacer(Modifier.height(10.dp))
        SegmentedControl(
            options = displayModeOptions,
            selected = mode, onSelect = onMode, modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(8.dp))
        Crossfade(mode, label = "modeDesc") {
            Text(
                it.description,
                style = MaterialTheme.typography.bodySmall, color = c.textTertiary,
            )
        }
        Spacer(Modifier.height(20.dp))
        SectionLabel("Stream quality")
        Spacer(Modifier.height(10.dp))
        SegmentedControl(
            options = listOf(
                SegmentOption(Quality.PERFORMANCE, "Speed", Icons.Rounded.Bolt),
                SegmentOption(Quality.BALANCED, "Balanced", Icons.Rounded.Balance),
                SegmentOption(Quality.QUALITY, "Quality", Icons.Rounded.Diamond),
            ),
            selected = quality, onSelect = onQuality, modifier = Modifier.fillMaxWidth(),
        )
    }
}

/* ------------------------------------------------------------------ hosts */

private fun LazyListScope.hostsSection(
    groups: List<HostGroup>,
    streaming: ConnectionState.Streaming?,
    vm: MainViewModel,
    onOpenHelp: () -> Unit,
    onManual: () -> Unit,
    lan: LocalNetworkPermissionState,
) {
    item(key = "header") { HostsHeader(scanning = true, count = groups.size, onManual = onManual) }
    if (!lan.granted) item(key = "lan") { LocalNetworkCard(lan) }
    if (streaming != null) item(key = "session") { SessionCard(streaming, onDisconnect = vm::disconnect) }
    if (groups.isEmpty()) {
        item(key = "empty") { EmptyScanning(onOpenHelp) }
    } else {
        items(groups, key = { it.key }) { g ->
            AnimatedEntrance(Modifier.animateItem()) {
                HostCard(
                    g,
                    connected = g.contains(streaming?.host),
                    onConnect = { vm.connect(g.primary) },
                )
            }
        }
        item(key = "hint") {
            Text(
                "Don't see your computer? Make sure PlexiChore Desktop is running, then try Connect by IP.",
                style = MaterialTheme.typography.bodySmall, color = Plexi.colors.textSecondary,
                modifier = Modifier.padding(horizontal = 6.dp, vertical = 6.dp),
            )
        }
    }
}

/** Android 17+: Wi-Fi discovery and LAN connections need the local network permission. */
@Composable
private fun LocalNetworkCard(lan: LocalNetworkPermissionState) {
    val c = Plexi.colors
    GlassCard(Modifier.fillMaxWidth(), highlighted = true, contentPadding = PaddingValues(20.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            IconBadge(Icons.Rounded.WifiFind, size = 44.dp)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text("Allow Wi-Fi discovery", style = MaterialTheme.typography.titleMedium, color = c.textPrimary)
                Spacer(Modifier.height(4.dp))
                Text(
                    "Android needs your permission to find computers on your local network and connect to them. " +
                        "USB keeps working without it.",
                    style = MaterialTheme.typography.bodySmall, color = c.textSecondary,
                )
            }
        }
        Spacer(Modifier.height(14.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            GradientButton(if (lan.permanentlyDenied) "Open settings" else "Allow", lan::request, icon = Icons.Rounded.Wifi, height = 48.dp)
        }
    }
}

@Composable
private fun AnimatedEntrance(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    var visible by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { visible = true }
    AnimatedVisibility(
        visible, modifier,
        enter = fadeIn(tween(450)) + slideInVertically(spring(dampingRatio = 0.8f, stiffness = Spring.StiffnessLow)) { it / 3 },
    ) { content() }
}

@Composable
private fun HostsHeader(scanning: Boolean, count: Int, onManual: () -> Unit) {
    val c = Plexi.colors
    Row(Modifier.fillMaxWidth().padding(top = 4.dp, bottom = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text("Nearby computers", style = MaterialTheme.typography.headlineSmall, color = c.textPrimary)
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (scanning) PulsingDot(c.accentEnd)
                Spacer(Modifier.width(8.dp))
                Text(
                    if (count == 0) "Scanning USB and Wi-Fi…" else "$count found · still scanning",
                    style = MaterialTheme.typography.bodySmall, color = c.textSecondary,
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        GhostButton("Connect by IP", onManual, icon = Icons.Rounded.Lan, height = 48.dp)
    }
}

@Composable
fun PulsingDot(color: Color, size: Dp = 8.dp) {
    val inf = rememberInfiniteTransition(label = "dot")
    val a by inf.animateFloat(0.25f, 1f, infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "a")
    val s by inf.animateFloat(1f, 2.4f, infiniteRepeatable(tween(1400)), label = "s")
    Box(contentAlignment = Alignment.Center, modifier = Modifier.size(size * 2.4f)) {
        Box(Modifier.size(size).graphicsLayer { scaleX = s; scaleY = s; alpha = (2.4f - s) / 1.4f * 0.5f }.clip(CircleShape).background(color))
        Box(Modifier.size(size).alpha(a.coerceAtLeast(0.6f)).clip(CircleShape).background(color))
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun HostCard(g: HostGroup, connected: Boolean, onConnect: () -> Unit) {
    val c = Plexi.colors
    val host = g.primary
    val mac = host.os.equals("macos", true)
    val fontScale = LocalDensity.current.fontScale
    GlassCard(Modifier.fillMaxWidth(), highlighted = connected, onClick = onConnect, contentPadding = PaddingValues(18.dp)) {
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            // Narrow card or big text: the action moves below so the name keeps its width.
            val narrow = maxWidth < 460.dp || fontScale >= 1.5f
            // The "USB" route may really be wireless debugging (adb over Wi-Fi, no cable): say so instead of "USB cable".
            val usbWireless = Transport.USB in g.transports && HostDiscovery.usbIsWirelessDebugging(LocalContext.current)
            val via = listOfNotNull(
                if (Transport.USB in g.transports) (if (usbWireless) "wireless debugging" else "USB cable") else null,
                g.lanAddress,
            )
            val title = if (host.name == HostDiscovery.UNKNOWN_USB_NAME && usbWireless) "Computer via wireless debugging" else host.name
            // OS unknown (USB before the first session): show only how it is connected, never a guess.
            val osLabel = when {
                mac -> "macOS"
                host.os.equals("windows", true) -> "Windows"
                else -> null
            }
            val subtitle = listOfNotNull(osLabel, *via.toTypedArray()).joinToString(" · ")
            val action: @Composable () -> Unit = {
                if (connected) StatusChip("Connected", c.success, icon = Icons.Rounded.CheckCircle)
                else GradientButton("Connect", onConnect, icon = Icons.AutoMirrored.Rounded.ArrowForward, height = 48.dp)
            }
            Column {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconBadge(if (mac) Icons.Rounded.LaptopMac else Icons.Rounded.LaptopWindows, size = if (narrow) 44.dp else 58.dp)
                    Spacer(Modifier.width(if (narrow) 12.dp else 16.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            title, style = MaterialTheme.typography.titleLarge, color = c.textPrimary,
                            maxLines = if (narrow) 2 else 1, overflow = TextOverflow.Ellipsis,
                        )
                        Spacer(Modifier.height(2.dp))
                        Text(subtitle, style = MaterialTheme.typography.bodySmall, color = c.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Spacer(Modifier.height(10.dp))
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            g.transports.forEach { t ->
                                when (t) {
                                    Transport.USB ->
                                        if (usbWireless) StatusChip("Wireless debugging", c.accentEnd, icon = Icons.Rounded.Wifi)
                                        else StatusChip("USB", c.accentEnd, icon = Icons.Rounded.Usb)
                                    Transport.WIFI -> StatusChip("Wi-Fi", c.accentStart, icon = Icons.Rounded.Wifi)
                                    Transport.MANUAL -> StatusChip("Manual", c.accentMid, icon = Icons.Rounded.Lan)
                                }
                            }
                            if (g.virtualDisplay) StatusChip("Extended display", c.success, icon = Icons.Rounded.Monitor)
                            else StatusChip("Mirror only", c.warning, icon = Icons.AutoMirrored.Rounded.ScreenShare)
                        }
                    }
                    if (!narrow) {
                        Spacer(Modifier.width(12.dp))
                        action()
                    }
                }
                if (narrow) {
                    Spacer(Modifier.height(14.dp))
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) { action() }
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SessionCard(s: ConnectionState.Streaming, onDisconnect: () -> Unit) {
    val c = Plexi.colors
    val ctx = LocalContext.current
    val fontScale = LocalDensity.current.fontScale
    GlassCard(Modifier.fillMaxWidth(), highlighted = true, contentPadding = PaddingValues(20.dp)) {
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            // Buttons go below the text when they would squeeze it (narrow card or big text).
            val stacked = maxWidth < 620.dp || fontScale > 1.3f
            val info: @Composable (Modifier) -> Unit = { m ->
                Row(m, verticalAlignment = Alignment.CenterVertically) {
                    PulsingDot(c.success, 10.dp)
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            "Streaming from ${s.host.name}", style = MaterialTheme.typography.titleMedium, color = c.textPrimary,
                            maxLines = if (stacked) 2 else 1, overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            "${s.config.width}×${s.config.height} · ${s.config.fps} fps · ${s.config.codec.uppercase()} · " +
                                s.config.mode.sessionLabel,
                            style = MaterialTheme.typography.bodySmall, color = c.textSecondary,
                            maxLines = 2, overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
            val disconnect: @Composable () -> Unit = {
                GhostButton("Disconnect", onDisconnect, icon = Icons.Rounded.LinkOff, contentColor = c.danger, height = 48.dp)
            }
            val open: @Composable () -> Unit = {
                GradientButton("Open display", {
                    runCatching {
                        ctx.startActivity(
                            Intent().setComponent(ComponentName(ctx, "com.pntapps.plexichore.display.DisplayActivity"))
                                .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
                        )
                    }
                }, icon = Icons.AutoMirrored.Rounded.OpenInNew, height = 48.dp)
            }
            if (stacked) {
                Column {
                    info(Modifier.fillMaxWidth())
                    Spacer(Modifier.height(14.dp))
                    FlowRow(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) { disconnect(); open() }
                }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    info(Modifier.weight(1f))
                    Spacer(Modifier.width(12.dp))
                    disconnect()
                    Spacer(Modifier.width(10.dp))
                    open()
                }
            }
        }
    }
}

@Composable
private fun EmptyScanning(onOpenHelp: () -> Unit) {
    val c = Plexi.colors
    val adaptive = LocalAdaptive.current
    val fontScale = LocalDensity.current.fontScale
    GlassCard(Modifier.fillMaxWidth(), contentPadding = PaddingValues(26.dp)) {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            val radar = when {
                adaptive.compactHeight -> 150.dp
                adaptive.twoPane -> 230.dp
                else -> 260.dp
            }
            RadarScanner(Modifier.widthIn(max = radar).fillMaxWidth())
            Spacer(Modifier.height(18.dp))
            Text("Looking for computers", style = MaterialTheme.typography.titleLarge, color = c.textPrimary, textAlign = TextAlign.Center)
            Spacer(Modifier.height(4.dp))
            Text(
                "Open PlexiChore Desktop on your Windows PC or Mac. It will appear here automatically.",
                style = MaterialTheme.typography.bodyMedium, color = c.textSecondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.widthIn(max = 420.dp),
            )
        }
        Spacer(Modifier.height(22.dp))
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val tips: List<Triple<ImageVector, String, String>> = listOf(
                Triple(Icons.Rounded.Usb, "USB", "Plug in the cable and allow USB debugging."),
                Triple(Icons.Rounded.WifiFind, "Same Wi-Fi", "Tablet and computer on one network."),
                Triple(Icons.Rounded.DesktopWindows, "Firewall", "Allow PlexiChore Desktop on private networks."),
            )
            if (maxWidth >= 520.dp * fontScale.coerceIn(1f, 1.6f)) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                    tips.forEach { (i, t, b) -> Tip(i, t, b, Modifier.weight(1f)) }
                }
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                    tips.forEach { (i, t, b) -> Tip(i, t, b, Modifier.fillMaxWidth()) }
                }
            }
        }
        Spacer(Modifier.height(16.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
            GhostButton("Open setup guide", onOpenHelp, icon = Icons.AutoMirrored.Rounded.HelpOutline, height = 48.dp)
        }
    }
}

@Composable
private fun Tip(icon: ImageVector, title: String, body: String, modifier: Modifier = Modifier) {
    val c = Plexi.colors
    Column(
        modifier
            .clip(RoundedCornerShape(18.dp))
            .background(if (c.isDark) Color.White.copy(alpha = 0.03f) else Color.White.copy(alpha = 0.5f))
            .padding(14.dp),
    ) {
        IconBadge(icon, size = 34.dp)
        Spacer(Modifier.height(10.dp))
        Text(title, style = MaterialTheme.typography.titleSmall, color = c.textPrimary)
        Spacer(Modifier.height(2.dp))
        Text(body, style = MaterialTheme.typography.bodySmall, color = c.textSecondary)
    }
}
