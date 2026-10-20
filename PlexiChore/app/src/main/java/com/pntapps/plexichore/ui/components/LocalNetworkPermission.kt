package com.pntapps.plexichore.ui.components

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LifecycleResumeEffect

/**
 * Android 17 (API 37) Local Network Protection: apps targeting 37 need the runtime permission
 * `android.permission.ACCESS_LOCAL_NETWORK` (NEARBY_DEVICES group) for any LAN traffic — Wi-Fi
 * discovery (UDP 47801) and connecting to a computer's LAN IP. USB (adb reverse, 127.0.0.1) is
 * loopback and keeps working without it. Below API 37 the permission does not exist: always granted.
 */
object LocalNetworkPermission {
    const val MIN_SDK = 37

    /** Same string as `Manifest.permission.ACCESS_LOCAL_NETWORK` in the API 37 SDK. */
    @Suppress("InlinedApi")
    const val NAME: String = Manifest.permission.ACCESS_LOCAL_NETWORK

    val required: Boolean get() = Build.VERSION.SDK_INT >= MIN_SDK

    fun isGranted(context: Context): Boolean =
        !required || ContextCompat.checkSelfPermission(context, NAME) == PackageManager.PERMISSION_GRANTED

    fun openAppSettings(context: Context) {
        runCatching {
            context.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }
}

@Stable
class LocalNetworkPermissionState internal constructor(
    granted: Boolean,
    private val launch: () -> Unit,
    private val openSettings: () -> Unit,
) {
    var granted by mutableStateOf(granted)
        internal set

    /** True after the user denied with "don't ask again": the system dialog no longer appears. */
    var permanentlyDenied by mutableStateOf(false)
        internal set

    fun request() = if (permanentlyDenied) openSettings() else launch()
}

/** Tracks the local-network permission and re-checks on every resume (the user may change it in Settings). */
@Composable
fun rememberLocalNetworkPermission(): LocalNetworkPermissionState {
    val ctx = LocalContext.current
    var holder: LocalNetworkPermissionState? = null
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        val s = holder ?: return@rememberLauncherForActivityResult
        s.granted = ok
        val activity = ctx.findActivity()
        s.permanentlyDenied = !ok && activity != null &&
            !ActivityCompat.shouldShowRequestPermissionRationale(activity, LocalNetworkPermission.NAME)
    }
    val state = remember {
        LocalNetworkPermissionState(
            granted = LocalNetworkPermission.isGranted(ctx),
            launch = { if (LocalNetworkPermission.required) launcher.launch(LocalNetworkPermission.NAME) },
            openSettings = { LocalNetworkPermission.openAppSettings(ctx) },
        )
    }
    holder = state
    LifecycleResumeEffect(Unit) {
        state.granted = LocalNetworkPermission.isGranted(ctx)
        onPauseOrDispose { }
    }
    return state
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}
