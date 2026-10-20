package com.pntapps.plexichore.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Lan
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.clickable
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.pntapps.plexichore.ui.components.GhostButton
import com.pntapps.plexichore.ui.components.GlassCard
import com.pntapps.plexichore.ui.components.GradientButton
import com.pntapps.plexichore.ui.components.IconBadge
import com.pntapps.plexichore.ui.components.StatusChip
import com.pntapps.plexichore.ui.theme.Plexi

private val IP_REGEX = Regex("""^((25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(25[0-5]|2[0-4]\d|1?\d?\d)(:\d{1,5})?$""")

@Composable
fun ConnectByIpDialog(initial: String, onDismiss: () -> Unit, onConnect: (String) -> Unit) {
    val c = Plexi.colors
    var text by rememberSaveable { mutableStateOf("") }
    val valid = IP_REGEX.matches(text.trim())
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        GlassCard(
            Modifier.padding(24.dp).widthIn(max = 520.dp).fillMaxWidth().imePadding(),
            strong = true,
            shape = RoundedCornerShape(30.dp),
            contentPadding = PaddingValues(30.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconBadge(Icons.Rounded.Lan, size = 48.dp)
                Spacer(Modifier.width(14.dp))
                Column {
                    Text("Connect by IP", style = MaterialTheme.typography.headlineSmall, color = c.textPrimary)
                    Text("Find the address in PlexiChore Desktop.", style = MaterialTheme.typography.bodySmall, color = c.textSecondary)
                }
            }
            Spacer(Modifier.height(24.dp))
            OutlinedTextField(
                value = text,
                onValueChange = { v -> text = v.filter { it.isDigit() || it == '.' || it == ':' }.take(21) },
                modifier = Modifier.fillMaxWidth().focusRequester(focus),
                label = { Text("Computer IP address") },
                placeholder = { Text("192.168.1.24") },
                singleLine = true,
                isError = text.isNotEmpty() && !valid,
                supportingText = { Text(if (text.isNotEmpty() && !valid) "Enter an IPv4 address, optionally :port" else "Default port 47800") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { if (valid) onConnect(text.trim()) }),
                shape = RoundedCornerShape(16.dp),
                textStyle = MaterialTheme.typography.titleLarge,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = c.accentStart,
                    unfocusedBorderColor = c.glassBorderHighlight.copy(alpha = 0.35f),
                    focusedLabelColor = c.accentStart,
                    cursorColor = c.accentEnd,
                    focusedContainerColor = c.glass,
                    unfocusedContainerColor = c.glass,
                ),
            )
            if (initial.isNotBlank()) {
                Spacer(Modifier.height(8.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.History, null, tint = c.textTertiary, modifier = Modifier.padding(end = 8.dp))
                    Text("Recent", style = MaterialTheme.typography.labelMedium, color = c.textTertiary)
                    Spacer(Modifier.width(10.dp))
                    androidx.compose.foundation.layout.Box(Modifier.clip(RoundedCornerShape(50)).clickable { text = initial }) {
                        StatusChip(initial, c.accentEnd)
                    }
                }
            }
            Spacer(Modifier.height(24.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.End)) {
                GhostButton("Cancel", onDismiss)
                GradientButton("Connect", { onConnect(text.trim()) }, enabled = valid, icon = Icons.AutoMirrored.Rounded.ArrowForward, height = 48.dp)
            }
        }
    }
}

