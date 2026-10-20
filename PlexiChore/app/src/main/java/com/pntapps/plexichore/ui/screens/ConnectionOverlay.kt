package com.pntapps.plexichore.ui.screens

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import com.pntapps.plexichore.ui.components.plexiSafeAll
import com.pntapps.plexichore.ui.navigation.LocalAdaptive
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.HelpOutline
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pntapps.plexichore.core.ConnectionState
import com.pntapps.plexichore.core.DiscoveredHost
import com.pntapps.plexichore.core.Transport
import com.pntapps.plexichore.ui.MainViewModel
import com.pntapps.plexichore.ui.components.GhostButton
import com.pntapps.plexichore.ui.components.GlassCard
import com.pntapps.plexichore.ui.components.GradientButton
import com.pntapps.plexichore.ui.components.GradientText
import com.pntapps.plexichore.ui.components.LinkIllustration
import com.pntapps.plexichore.ui.theme.Plexi


/** Full-screen glass overlay for Connecting / AwaitingApproval / Failed (and a brief "Connected"). */
@Composable
fun ConnectionOverlay(vm: MainViewModel, onOpenHelp: () -> Unit) {
    val state by vm.state.collectAsStateWithLifecycle()
    val dismissed by vm.overlayDismissed.collectAsStateWithLifecycle()
    val haptic = LocalHapticFeedback.current
    val visible = !dismissed && (state is ConnectionState.Connecting || state is ConnectionState.AwaitingApproval || state is ConnectionState.Failed)

    LaunchedEffect(state::class) {
        when (state) {
            is ConnectionState.AwaitingApproval -> haptic.performHapticFeedback(HapticFeedbackType.LongPress)
            is ConnectionState.Failed -> haptic.performHapticFeedback(HapticFeedbackType.Reject)
            is ConnectionState.Streaming -> haptic.performHapticFeedback(HapticFeedbackType.Confirm)
            else -> Unit
        }
    }

    // Remember the last non-idle state so content stays put while the overlay animates out.
    val shown = remember { arrayOfNulls<ConnectionState>(1) }
    if (visible) shown[0] = state

    AnimatedVisibility(visible, enter = fadeIn(tween(250)), exit = fadeOut(tween(250))) {
        val c = Plexi.colors
        Box(
            Modifier
                .fillMaxSize()
                .background(if (c.isDark) Color(0xF2060812) else Color(0xEEF1F3FA))
                .clickable(remember { MutableInteractionSource() }, null) { },
            contentAlignment = Alignment.Center,
        ) {
            val s = shown[0] ?: return@Box
            AnimatedContent(
                targetState = s,
                contentKey = { it::class },
                transitionSpec = {
                    (fadeIn(tween(300)) + scaleIn(spring(dampingRatio = 0.75f, stiffness = Spring.StiffnessLow), initialScale = 0.92f)) togetherWith
                        (fadeOut(tween(180)) + scaleOut(targetScale = 0.96f))
                },
                label = "overlay",
            ) { st ->
                // Short or narrow windows (phones, landscape 7" at large font, split screen): the
                // card scrolls inside the safe area instead of pushing its buttons off-screen.
                val compact = LocalAdaptive.current.compactHeight
                BoxWithConstraints(Modifier.fillMaxSize().plexiSafeAll()) {
                    val minH = maxHeight
                    Column(
                        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).heightIn(min = minH),
                        verticalArrangement = Arrangement.Center,
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        GlassCard(
                            Modifier.padding(if (compact) 12.dp else 24.dp).widthIn(max = 560.dp).fillMaxWidth(),
                            strong = true,
                            shape = RoundedCornerShape(32.dp),
                            contentPadding = if (compact) PaddingValues(horizontal = 22.dp, vertical = 20.dp)
                            else PaddingValues(horizontal = 36.dp, vertical = 34.dp),
                        ) {
                            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                                when (st) {
                                    is ConnectionState.Connecting -> ConnectingContent(st.host, compact, vm::cancel)
                                    is ConnectionState.AwaitingApproval -> ApprovalContent(st.host, st.code, compact, vm::cancel)
                                    is ConnectionState.Failed -> FailedContent(st, compact, vm::retry, vm::cancel, onOpenHelp)
                                    else -> Unit
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun DiscoveredHost.via() = when (transport) {
    Transport.USB -> if (com.pntapps.plexichore.core.HostDiscovery.lastUsbLink == "usb-wireless-adb") "via wireless debugging (adb)" else "via USB cable"
    Transport.WIFI -> if (usbNetwork) "via USB tethering · $address" else "via Wi-Fi · $address"
    Transport.MANUAL -> "via $address:$port"
}

@Composable
private fun ConnectingContent(host: DiscoveredHost, compact: Boolean, onCancel: () -> Unit) {
    val c = Plexi.colors
    LinkIllustration(Modifier.fillMaxWidth(if (compact) 0.5f else 0.85f).widthIn(max = if (compact) 220.dp else 420.dp))
    Spacer(Modifier.height(if (compact) 14.dp else 22.dp))
    Text("Connecting", style = MaterialTheme.typography.labelSmall, color = c.accentEnd)
    Spacer(Modifier.height(6.dp))
    Text(
        host.name, style = if (compact) MaterialTheme.typography.headlineSmall else MaterialTheme.typography.headlineMedium,
        color = c.textPrimary, textAlign = TextAlign.Center, maxLines = 3, overflow = TextOverflow.Ellipsis,
    )
    Spacer(Modifier.height(4.dp))
    Text(host.via(), style = MaterialTheme.typography.bodyMedium, color = c.textSecondary, textAlign = TextAlign.Center)
    Spacer(Modifier.height(if (compact) 16.dp else 24.dp))
    IndeterminateBar(Modifier.fillMaxWidth(0.7f))
    Spacer(Modifier.height(if (compact) 18.dp else 28.dp))
    GhostButton("Cancel", onCancel)
}

@Composable
private fun ApprovalContent(host: DiscoveredHost, code: String, compact: Boolean, onCancel: () -> Unit) {
    val c = Plexi.colors
    if (!compact) {
        Box(
            Modifier.size(56.dp).clip(RoundedCornerShape(18.dp))
                .background(Brush.linearGradient(listOf(c.accentStart.copy(alpha = 0.25f), c.accentEnd.copy(alpha = 0.18f)))),
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Rounded.Lock, null, tint = c.textPrimary, modifier = Modifier.size(26.dp)) }
        Spacer(Modifier.height(18.dp))
    }
    Text("Confirm this code on your computer", style = MaterialTheme.typography.headlineSmall, color = c.textPrimary, textAlign = TextAlign.Center)
    Spacer(Modifier.height(8.dp))
    Text(
        "${host.name} is asking to pair with this tablet. Check that the same code is shown there and click Approve.",
        style = MaterialTheme.typography.bodyMedium, color = c.textSecondary, textAlign = TextAlign.Center,
    )
    Spacer(Modifier.height(if (compact) 18.dp else 28.dp))
    // Digit size follows the available width so all digits always fit (phones, split screen).
    BoxWithConstraints(
        Modifier.fillMaxWidth().semantics { contentDescription = "Pairing code ${code.toList().joinToString(" ")}" },
        contentAlignment = Alignment.Center,
    ) {
        val n = code.length.coerceAtLeast(1)
        val gap = if (maxWidth < 360.dp) 8.dp else 14.dp
        val digitW = minOf(86.dp, (maxWidth - gap * (n - 1)) / n)
        Row(horizontalArrangement = Arrangement.spacedBy(gap)) {
            code.forEachIndexed { i, ch -> CodeDigit(ch, i, digitW) }
        }
    }
    Spacer(Modifier.height(if (compact) 18.dp else 28.dp))
    Row(verticalAlignment = Alignment.CenterVertically) {
        PulsingDot(c.accentEnd)
        Spacer(Modifier.width(6.dp))
        Text("Waiting for approval…", style = MaterialTheme.typography.bodySmall, color = c.textSecondary)
    }
    Spacer(Modifier.height(20.dp))
    GhostButton("Cancel", onCancel)
}

@Composable
private fun CodeDigit(ch: Char, index: Int, width: Dp) {
    val c = Plexi.colors
    val inf = rememberInfiniteTransition(label = "digit")
    val shimmer by inf.animateFloat(0f, 1f, infiniteRepeatable(tween(2400, delayMillis = 0, easing = LinearEasing)), label = "sh")
    val shape = RoundedCornerShape(width * 0.26f)
    Box(
        Modifier
            .size(width = width, height = width * 1.25f)
            .clip(shape)
            .background(if (c.isDark) Color.Black.copy(alpha = 0.35f) else Color.White)
            .border(1.5.dp, Brush.linearGradient(listOf(c.accentStart.copy(alpha = 0.8f), c.accentEnd.copy(alpha = 0.6f))), shape)
            .drawWithContent {
                drawContent()
                val p = ((shimmer * 1.6f) - index * 0.15f) % 1.6f
                val x = size.width * (p * 2f - 0.5f)
                drawRect(
                    Brush.linearGradient(listOf(Color.Transparent, Color.White.copy(alpha = 0.10f), Color.Transparent), Offset(x - 40f, 0f), Offset(x + 40f, size.height)),
                    Offset.Zero, Size(size.width, size.height),
                )
            },
        contentAlignment = Alignment.Center,
    ) {
        // Fixed to the box, not the user's font scale: the box itself already scales with width.
        val fontSize = with(LocalDensity.current) { (width * 0.62f).toSp() }
        GradientText(ch.toString(), MaterialTheme.typography.displayMedium.copy(fontSize = fontSize, lineHeight = fontSize))
    }
}

@Composable
private fun FailedContent(s: ConnectionState.Failed, compact: Boolean, onRetry: () -> Unit, onBack: () -> Unit, onHelp: () -> Unit) {
    val c = Plexi.colors
    LinkIllustration(Modifier.fillMaxWidth(if (compact) 0.5f else 0.85f).widthIn(max = if (compact) 220.dp else 420.dp), error = true)
    Spacer(Modifier.height(if (compact) 14.dp else 22.dp))
    Text("Couldn't connect", style = MaterialTheme.typography.headlineMedium, color = c.textPrimary, textAlign = TextAlign.Center)
    Spacer(Modifier.height(8.dp))
    // The core's messages usually name the host already ("X refused the connection"): never twice.
    val name = s.host?.name
    val message = if (name != null && !s.message.contains(name)) "$name: ${s.message}" else s.message
    Text(message, style = MaterialTheme.typography.bodyMedium, color = c.textSecondary, textAlign = TextAlign.Center)
    Spacer(Modifier.height(if (compact) 18.dp else 28.dp))
    @OptIn(ExperimentalLayoutApi::class)
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterHorizontally),
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        GhostButton("Back", onBack, icon = Icons.AutoMirrored.Rounded.ArrowBack)
        GradientButton("Try again", onRetry, icon = Icons.Rounded.Refresh)
    }
    Spacer(Modifier.height(10.dp))
    Text(
        "Open setup guide",
        style = MaterialTheme.typography.labelLarge, color = c.accentEnd,
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onHelp)
            .heightIn(min = 48.dp)
            .padding(horizontal = 12.dp, vertical = 14.dp),
    )
}

@Composable
private fun IndeterminateBar(modifier: Modifier = Modifier) {
    val c = Plexi.colors
    val inf = rememberInfiniteTransition(label = "bar")
    val p by inf.animateFloat(0f, 1f, infiniteRepeatable(tween(1300, easing = LinearEasing)), label = "p")
    Box(
        modifier.height(6.dp).clip(RoundedCornerShape(3.dp))
            .background(c.glassBorder)
            .drawWithContent {
                val w = size.width * 0.35f
                val x = -w + (size.width + w) * p
                drawRoundRect(
                    Brush.horizontalGradient(listOf(c.accentStart, c.accentEnd), x, x + w),
                    Offset(x, 0f), Size(w, size.height), androidx.compose.ui.geometry.CornerRadius(size.height / 2),
                )
            },
    )
}
