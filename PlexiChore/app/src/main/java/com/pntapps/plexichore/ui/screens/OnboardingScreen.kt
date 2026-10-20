package com.pntapps.plexichore.ui.screens

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.PagerState
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.automirrored.rounded.ViewQuilt
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Draw
import androidx.compose.material.icons.rounded.NotificationsActive
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material.icons.rounded.Usb
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material.icons.rounded.WifiFind
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.pntapps.plexichore.ui.components.BrandMark
import com.pntapps.plexichore.ui.components.ConnectIllustration
import com.pntapps.plexichore.ui.components.GhostButton
import com.pntapps.plexichore.ui.components.GradientButton
import com.pntapps.plexichore.ui.components.GradientText
import com.pntapps.plexichore.ui.components.HeroIllustration
import com.pntapps.plexichore.ui.components.IconBadge
import com.pntapps.plexichore.ui.components.LocalNetworkPermission
import com.pntapps.plexichore.ui.components.NotificationIllustration
import com.pntapps.plexichore.ui.components.StatusChip
import com.pntapps.plexichore.ui.components.plexiSafeAll
import com.pntapps.plexichore.ui.components.rememberLocalNetworkPermission
import com.pntapps.plexichore.ui.navigation.LocalAdaptive
import com.pntapps.plexichore.ui.theme.Plexi
import kotlinx.coroutines.launch
import kotlin.math.absoluteValue

@Composable
fun OnboardingScreen(onFinish: () -> Unit) {
    val pager = rememberPagerState { 3 }
    val scope = rememberCoroutineScope()
    val adaptive = LocalAdaptive.current
    val twoPane = adaptive.twoPane
    val compact = adaptive.compactHeight
    val ctx = LocalContext.current
    var notifGranted by remember {
        mutableStateOf(Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
    }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { notifGranted = it }
    val lan = rememberLocalNetworkPermission()
    val hPad = if (compact) 20.dp else 28.dp

    Column(Modifier.fillMaxSize().plexiSafeAll()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = hPad, vertical = if (compact) 8.dp else 16.dp).heightIn(min = 48.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            BrandMark(Modifier.size(34.dp))
            Spacer(Modifier.width(10.dp))
            Text("PlexiChore", style = MaterialTheme.typography.titleLarge, color = Plexi.colors.textPrimary, modifier = Modifier.weight(1f))
            if (pager.currentPage < 2) GhostButton("Skip", onFinish, height = 48.dp)
        }
        HorizontalPager(pager, Modifier.weight(1f).fillMaxWidth()) { page ->
            val offset = (pager.currentPage - page + pager.currentPageOffsetFraction).absoluteValue
            Box(
                Modifier.fillMaxSize().graphicsLayer {
                    alpha = 1f - offset.coerceIn(0f, 1f) * 0.6f
                    val sc = 1f - offset.coerceIn(0f, 1f) * 0.06f
                    scaleX = sc; scaleY = sc
                },
            ) {
                when (page) {
                    0 -> OnboardPage(
                        twoPane, compact, art = { HeroIllustration(it) },
                        eyebrow = "Welcome", title = "Turn your tablet into", accent = "a second screen.",
                        body = "PlexiChore makes this tablet a portable, touch-enabled monitor for your Windows PC or Mac — extend your desktop or mirror it, wherever you work.",
                        features = listOf(Feature(Icons.AutoMirrored.Rounded.ViewQuilt, "Extend or mirror"), Feature(Icons.Rounded.Draw, "Touch & pen"), Feature(Icons.Rounded.Speed, "Up to 120 fps")),
                    )
                    1 -> OnboardPage(
                        twoPane, compact, art = { ConnectIllustration(it) },
                        eyebrow = "How to connect", title = "Install the desktop app,", accent = "then plug in or go wireless.",
                        body = "Get PlexiChore Desktop for Windows or macOS. Connect with a USB cable for the lowest latency, or join the same Wi-Fi network — your computer shows up here automatically.",
                        features = listOf(Feature(Icons.Rounded.Usb, "USB: lowest latency"), Feature(Icons.Rounded.Wifi, "Wi-Fi: no cables")),
                    )
                    else -> OnboardPage(
                        twoPane, compact, art = { NotificationIllustration(it) },
                        eyebrow = "One last thing", title = "Stay in control", accent = "while you stream.",
                        body = if (LocalNetworkPermission.required) {
                            "PlexiChore shows a notification while the display is connected so you can see its status and disconnect at any time. " +
                                "To find your computer over Wi-Fi, Android also asks for access to devices on your local network."
                        } else {
                            "PlexiChore shows a notification while the display is connected so you can see its status and disconnect at any time."
                        },
                        features = emptyList(),
                        extra = {
                            @OptIn(ExperimentalLayoutApi::class)
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                if (notifGranted) StatusChip("Notifications allowed", Plexi.colors.success, icon = Icons.Rounded.CheckCircle)
                                else GhostButton("Allow notifications", {
                                    if (Build.VERSION.SDK_INT >= 33) launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
                                }, icon = Icons.Rounded.NotificationsActive)
                                if (LocalNetworkPermission.required) {
                                    if (lan.granted) StatusChip("Wi-Fi discovery allowed", Plexi.colors.success, icon = Icons.Rounded.CheckCircle)
                                    else GhostButton(
                                        if (lan.permanentlyDenied) "Allow Wi-Fi discovery in Settings" else "Allow Wi-Fi discovery",
                                        lan::request, icon = Icons.Rounded.WifiFind,
                                    )
                                }
                            }
                        },
                    )
                }
            }
        }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = hPad, vertical = if (compact) 10.dp else 20.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            PagerDots(pager)
            Spacer(Modifier.weight(1f))
            val last = pager.currentPage == 2
            GradientButton(
                if (last) "Get started" else "Next",
                { if (last) onFinish() else scope.launch { pager.animateScrollToPage(pager.currentPage + 1) } },
                icon = Icons.AutoMirrored.Rounded.ArrowForward,
                modifier = Modifier.widthIn(min = if (compact) 140.dp else 170.dp),
                height = if (compact) 48.dp else 56.dp,
            )
        }
    }
}

private data class Feature(val icon: ImageVector, val label: String)

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun OnboardPage(
    twoPane: Boolean,
    compact: Boolean,
    art: @Composable (Modifier) -> Unit,
    eyebrow: String,
    title: String,
    accent: String,
    body: String,
    features: List<Feature>,
    extra: (@Composable () -> Unit)? = null,
) {
    val c = Plexi.colors
    val titleStyle = if (compact) MaterialTheme.typography.headlineMedium else MaterialTheme.typography.displaySmall
    val text: @Composable (Modifier) -> Unit = { m ->
        Column(m) {
            GradientText(eyebrow.uppercase(), MaterialTheme.typography.labelSmall)
            Spacer(Modifier.height(if (compact) 8.dp else 12.dp))
            Text(title, style = titleStyle, color = c.textPrimary)
            GradientText(accent, titleStyle)
            Spacer(Modifier.height(if (compact) 12.dp else 18.dp))
            Text(body, style = MaterialTheme.typography.bodyLarge, color = c.textSecondary)
            if (features.isNotEmpty()) {
                Spacer(Modifier.height(if (compact) 16.dp else 26.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    features.forEach { f ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            IconBadge(f.icon, size = 34.dp)
                            Spacer(Modifier.width(8.dp))
                            Text(f.label, style = MaterialTheme.typography.labelLarge, color = c.textPrimary)
                        }
                    }
                }
            }
            if (extra != null) {
                Spacer(Modifier.height(if (compact) 16.dp else 26.dp))
                extra()
            }
        }
    }
    // Pages scroll when the text does not fit (short windows, large font) and stay centred when it does.
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val ratio = 100f / 62f
        val minH = maxHeight
        if (twoPane) {
            val artW: Dp = minOf(maxWidth * 0.5f, (maxHeight - 24.dp) * ratio)
            Row(
                Modifier.fillMaxSize().padding(horizontal = if (compact) 32.dp else 56.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(if (compact) 32.dp else 56.dp),
            ) {
                Box(Modifier.weight(1f), contentAlignment = Alignment.Center) { art(Modifier.widthIn(max = artW).fillMaxWidth()) }
                Column(
                    Modifier.weight(0.9f).verticalScroll(rememberScrollState()).heightIn(min = minH),
                    verticalArrangement = Arrangement.Center,
                ) {
                    Spacer(Modifier.height(8.dp))
                    text(Modifier.fillMaxWidth())
                    Spacer(Modifier.height(8.dp))
                }
            }
        } else {
            // Art takes at most ~38% of the height so the text always starts on screen.
            val artW: Dp = minOf(maxWidth - 80.dp, maxHeight * 0.38f * ratio, 560.dp)
            Column(
                Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).heightIn(min = minH)
                    .padding(horizontal = if (compact) 24.dp else 40.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                art(Modifier.widthIn(max = artW).fillMaxWidth())
                Spacer(Modifier.height(if (compact) 20.dp else 40.dp))
                text(Modifier.fillMaxWidth())
                Spacer(Modifier.height(12.dp))
            }
        }
    }
}

@Composable
private fun PagerDots(pager: PagerState) {
    val c = Plexi.colors
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        repeat(pager.pageCount) { i ->
            val active = pager.currentPage == i
            val w by animateDpAsState(if (active) 34.dp else 10.dp, label = "dotw")
            val col by animateColorAsState(if (active) c.accentStart else c.textTertiary.copy(alpha = 0.4f), label = "dotc")
            Box(
                Modifier.height(10.dp).width(w).clip(RoundedCornerShape(5.dp))
                    .background(if (active) c.accentBrush else Brush.linearGradient(listOf(col, col))),
            )
        }
    }
}
