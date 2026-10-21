package com.pntapps.plexichore.ui.screens

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import com.pntapps.plexichore.ui.components.plexiSafeTopAndSides
import com.pntapps.plexichore.ui.components.safeBottomPadding
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AspectRatio
import androidx.compose.material.icons.rounded.Cable
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Keyboard
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.FormatSize
import androidx.compose.material.icons.rounded.Laptop
import androidx.compose.material.icons.rounded.Mouse
import androidx.compose.material.icons.rounded.Pin
import androidx.compose.material.icons.rounded.Security
import androidx.compose.material.icons.rounded.Speed
import androidx.compose.material.icons.rounded.TouchApp
import androidx.compose.material.icons.rounded.Usb
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.pntapps.plexichore.R
import com.pntapps.plexichore.ui.components.ConnectIllustration
import com.pntapps.plexichore.ui.components.GlassCard
import com.pntapps.plexichore.ui.components.IconBadge
import com.pntapps.plexichore.ui.components.SegmentOption
import com.pntapps.plexichore.ui.components.SegmentedControl
import com.pntapps.plexichore.ui.navigation.LocalAdaptive
import com.pntapps.plexichore.ui.theme.Plexi

private data class Step(val title: String, val body: String)

private val usbSteps = listOf(
    Step("Install PlexiChore Desktop", "Download and run the companion app on your Windows PC or Mac. It includes everything needed for USB."),
    Step("Turn on Developer options", "On this tablet open Settings › About tablet › Software information and tap Build number 7 times."),
    Step("Enable USB debugging", "Go to Settings › Developer options and switch on USB debugging."),
    Step("Plug in the cable", "Connect the tablet to your computer with a USB-C cable and tap Allow on the \"Allow USB debugging?\" prompt. Tick Always allow."),
    Step("Connect", "Your computer appears under Nearby computers with a USB badge. Tap Connect — no pairing needed."),
)

private val wifiSteps = listOf(
    Step("Install PlexiChore Desktop", "Download and run the companion app on your Windows PC or Mac and leave it open."),
    Step("Join the same network", "Make sure the tablet and the computer are on the same Wi-Fi network (5 GHz or Wi-Fi 6 works best)."),
    Step("Allow through the firewall", "When Windows asks, allow PlexiChore Desktop on private networks. On macOS allow incoming connections."),
    Step("Connect & pair", "Tap your computer under Nearby computers. The first time, confirm the 4-digit code on your computer."),
    Step("Not listed?", "Use Connect by IP on the home screen with the address shown in PlexiChore Desktop."),
)

@Composable
fun HelpScreen(onBack: () -> Unit) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    val twoPane = LocalAdaptive.current.twoPane
    val bottom = safeBottomPadding() + 28.dp

    Column(Modifier.fillMaxSize().plexiSafeTopAndSides()) {
        ScreenHeader("Setup guide", "Get connected in a couple of minutes", onBack)
        val stepsPane: @Composable (Modifier) -> Unit = { m ->
            Column(m, verticalArrangement = Arrangement.spacedBy(18.dp)) {
                SegmentedControl(
                    listOf(SegmentOption(0, "USB cable", Icons.Rounded.Usb), SegmentOption(1, "Wi-Fi", Icons.Rounded.Wifi)),
                    tab, { tab = it }, Modifier.fillMaxWidth(), height = 52.dp,
                )
                AnimatedContent(tab, transitionSpec = { (fadeIn() + slideInVertically { it / 12 }) togetherWith fadeOut() }, label = "steps") { t ->
                    GlassCard(Modifier.fillMaxWidth(), contentPadding = PaddingValues(26.dp)) {
                        val steps = if (t == 0) usbSteps else wifiSteps
                        steps.forEachIndexed { i, s -> StepRow(i + 1, s, last = i == steps.lastIndex) }
                    }
                }
            }
        }
        if (twoPane) {
            Row(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(start = 28.dp, end = 28.dp, bottom = bottom),
                horizontalArrangement = Arrangement.spacedBy(24.dp),
            ) {
                Column(Modifier.weight(0.58f), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                    stepsPane(Modifier.fillMaxWidth())
                    StreamingInfo()
                }
                Column(Modifier.weight(0.42f), verticalArrangement = Arrangement.spacedBy(20.dp)) { SideInfo() }
            }
        } else {
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(start = 24.dp, end = 24.dp, bottom = bottom),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                stepsPane(Modifier.fillMaxWidth())
                StreamingInfo()
                SideInfo()
            }
        }
    }
}

@Composable
private fun StepRow(n: Int, step: Step, last: Boolean) {
    val c = Plexi.colors
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxHeight()) {
            Box(
                Modifier.size(36.dp).clip(CircleShape).background(c.accentBrush),
                contentAlignment = Alignment.Center,
            ) { Text("$n", style = MaterialTheme.typography.titleMedium, color = Color.White) }
            if (!last) Box(
                Modifier.padding(vertical = 6.dp).width(2.dp).weight(1f)
                    .background(Brush.verticalGradient(listOf(c.accentStart.copy(alpha = 0.6f), c.accentEnd.copy(alpha = 0.1f)))),
            )
        }
        Spacer(Modifier.width(18.dp))
        Column(Modifier.padding(bottom = if (last) 0.dp else 22.dp, top = 6.dp)) {
            Text(step.title, style = MaterialTheme.typography.titleMedium, color = c.textPrimary)
            Spacer(Modifier.height(4.dp))
            Text(step.body, style = MaterialTheme.typography.bodyMedium, color = c.textSecondary)
        }
    }
}

@Composable
private fun SideInfo() {
    val c = Plexi.colors
    GlassCard(Modifier.fillMaxWidth(), contentPadding = PaddingValues(0.dp)) {
        ConnectIllustration(Modifier.fillMaxWidth().padding(20.dp))
        Column(Modifier.padding(start = 24.dp, end = 24.dp, bottom = 24.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.Download, null, tint = c.accentEnd, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text("PlexiChore Desktop", style = MaterialTheme.typography.titleMedium, color = c.textPrimary)
            }
            Spacer(Modifier.height(4.dp))
            Text("Free for Windows 10/11 and macOS 12+.\n" + stringResource(R.string.desktop_app_url), style = MaterialTheme.typography.bodyMedium, color = c.textSecondary)
        }
    }
    GlassCard(Modifier.fillMaxWidth(), contentPadding = PaddingValues(24.dp)) {
        Text("Troubleshooting", style = MaterialTheme.typography.titleLarge, color = c.textPrimary)
        Spacer(Modifier.height(16.dp))
        Trouble(Icons.Rounded.Cable, "USB host not showing", "Turn on USB debugging (see the USB cable steps), re-plug the cable, accept the debugging prompt, and use a data-capable cable (not charge-only).")
        Trouble(Icons.Rounded.WifiOff, "Wi-Fi host not showing", "Same network on both. Guest networks and VPNs often block discovery. On a Mac allow PlexiChore under Privacy & Security › Local Network. Or try Connect by IP.")
        Trouble(Icons.Rounded.Security, "Connection refused", "Allow PlexiChore Desktop through your firewall on TCP 47800 and UDP 47801.")
        Trouble(Icons.Rounded.Pin, "Pairing code", "The first Wi-Fi connection shows a 4-digit code here. Approve the same code on your computer. USB never needs pairing.")
        Trouble(Icons.Rounded.Speed, "Laggy or choppy", "Use the USB cable rather than Wi-Fi and pick H.264 in Settings › Codec. Lower resolution or bitrate if needed.")
        Trouble(Icons.Rounded.AspectRatio, "Black borders", "Update PlexiChore on this tablet, then rotate it once.")
        Trouble(Icons.Rounded.Laptop, "MacBook lid closed", "On the Mac turn on Extended display › Options › Keep the tablet on with the lid closed (charger connected). Otherwise the tablet display goes away 10 s after closing the lid.")
        Trouble(Icons.Rounded.CheckCircle, "Extend not available", "Windows needs the PlexiChore virtual display driver. Mirror always works.", last = true)
    }
}

/** Emergency release + in-stream controls (left column on tablets, under the steps). */
@Composable
private fun StreamingInfo() {
    val c = Plexi.colors
    GlassCard(Modifier.fillMaxWidth(), contentPadding = PaddingValues(24.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.Warning, null, tint = c.danger, modifier = Modifier.size(22.dp))
            Spacer(Modifier.width(10.dp))
            Text("Mac screen black or stuck?", style = MaterialTheme.typography.titleLarge, color = c.textPrimary)
        }
        Spacer(Modifier.height(8.dp))
        Text(
            "On the Mac press ⌃⌥⌘D (Control-Option-Command-D), or choose Release Extended Display in the PlexiChore menu bar menu. " +
                "The tablet display is removed at once and your screens come back; the tablet mirrors for a short while.",
            style = MaterialTheme.typography.bodyMedium, color = c.textSecondary,
        )
    }
    GlassCard(Modifier.fillMaxWidth(), contentPadding = PaddingValues(24.dp)) {
        Text("While streaming", style = MaterialTheme.typography.titleLarge, color = c.textPrimary)
        Spacer(Modifier.height(16.dp))
        Trouble(Icons.Rounded.TouchApp, "Show the controls", "Swipe down from the top edge or tap with three fingers.")
        Trouble(Icons.Rounded.FormatSize, "Text too small or large", "Use − / + in the controls (or Settings › Display size). The screen blanks for about a second while it resizes.")
        Trouble(Icons.Rounded.Mouse, "Touch, Mouse or Input off", "Tap the input button in the controls to switch between them.")
        Trouble(Icons.Rounded.Keyboard, "Type on the computer", "Tap the keyboard button (floating, or in the controls). Keys above the keyboard add Esc, Tab, Ctrl, Alt, ⌘/Win, arrows and Delete — tap Ctrl, Alt or ⌘/Win once for the next key, twice to keep it on. A connected keyboard works too.")
        Trouble(Icons.Rounded.Close, "Disconnect", "Tap × in the controls. Your computer's screens go back to normal.", last = true)
    }
}

@Composable
private fun Trouble(icon: ImageVector, title: String, body: String, last: Boolean = false) {
    val c = Plexi.colors
    Row(Modifier.padding(bottom = if (last) 0.dp else 16.dp)) {
        IconBadge(icon, size = 36.dp)
        Spacer(Modifier.width(14.dp))
        Column {
            Text(title, style = MaterialTheme.typography.titleSmall, color = c.textPrimary)
            Text(body, style = MaterialTheme.typography.bodySmall, color = c.textSecondary)
        }
    }
}
