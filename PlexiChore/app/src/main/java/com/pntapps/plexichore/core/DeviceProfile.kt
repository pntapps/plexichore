package com.pntapps.plexichore.core

import android.content.Context
import android.hardware.display.DisplayManager
import android.media.MediaCodecInfo
import android.media.MediaCodecInfo.CodecProfileLevel
import android.media.MediaFormat
import android.os.Build
import android.provider.Settings
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import android.view.InputDevice
import java.util.UUID
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** A frame size this tablet's H.264 decoder can handle, and the highest frame rate at that size. */
internal data class DecodeMode(val width: Int, val height: Int, val maxFps: Int)

/** Facts about this tablet that go into HELLO. Rebuilt for every connection (fold/unfold, DeX, resolution changes). */
internal data class DeviceProfile(
    val deviceId: String,
    val deviceName: String,
    val model: String,
    /** Native panel size, landscape (long edge first). */
    val widthPx: Int,
    val heightPx: Int,
    val densityDpi: Int,
    val refreshHz: Int,
    val codecs: List<String>,
    val maxDecodeWidth: Int,
    val maxDecodeHeight: Int,
    val hasStylus: Boolean,
    /** Sizes the decoder really supports (landscape), largest first, each with its max fps. */
    val decodeModes: List<DecodeMode> = emptyList(),
    /** "high" | "main" | "baseline", best first. */
    val h264Profiles: List<String> = emptyList(),
    /** Highest H.264 level, e.g. "5.1"; empty when unknown. */
    val h264MaxLevel: String = "",
    /** Large screens (sw ≥ 600dp) ignore orientation locks on Android 16+, so the stream follows the tablet. */
    val followsOrientation: Boolean = false,
) {
    companion object {
        private const val TAG = "PlexiProfile"
        private const val PREFS = "plexi_core"
        private const val KEY_DEVICE_ID = "device_id"

        fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        fun deviceId(context: Context): String {
            val p = prefs(context)
            p.getString(KEY_DEVICE_ID, null)?.let { return it }
            val id = UUID.randomUUID().toString()
            p.edit().putString(KEY_DEVICE_ID, id).apply()
            return id
        }

        fun build(context: Context): DeviceProfile {
            val dm = context.getSystemService(DisplayManager::class.java)
            val display = dm.getDisplay(Display.DEFAULT_DISPLAY)
            val real = DisplayMetrics()
            @Suppress("DEPRECATION")
            display.getRealMetrics(real)
            val w = max(real.widthPixels, real.heightPixels)
            val h = min(real.widthPixels, real.heightPixels)
            // Match modes by aspect ratio, not exact width: "wm size", One UI's FHD+/WQXGA switch and
            // DeX change the logical size while the physical modes stay the same.
            val aspect = w.toFloat() / h
            val refresh = display.supportedModes
                .filter { abs(max(it.physicalWidth, it.physicalHeight).toFloat() / min(it.physicalWidth, it.physicalHeight) - aspect) < 0.03f }
                .maxOfOrNull { it.refreshRate }
                ?: display.refreshRate
            val avc = H264Decoder.findDecoder()
            val modes = avc?.let { decodeModes(it, w, h) }.orEmpty()
            val max = modes.maxByOrNull { it.width.toLong() * it.height }
            val (profiles, level) = avc?.let { profilesAndLevel(it) } ?: (emptyList<String>() to "")
            val sw = context.resources.configuration.smallestScreenWidthDp
            return DeviceProfile(
                deviceId = deviceId(context),
                deviceName = deviceName(context),
                model = Build.MODEL,
                widthPx = w,
                heightPx = h,
                densityDpi = context.resources.displayMetrics.densityDpi,
                refreshHz = refresh.roundToInt().coerceAtLeast(30),
                codecs = if (avc != null) listOf("h264", "mjpeg") else listOf("mjpeg"),
                maxDecodeWidth = max?.width ?: w,
                maxDecodeHeight = max?.height ?: h,
                hasStylus = hasStylus(),
                decodeModes = modes,
                h264Profiles = profiles,
                h264MaxLevel = level,
                followsOrientation = sw >= 600,
            ).also { Log.i(TAG, "Profile: ${it.widthPx}x${it.heightPx}@${it.refreshHz} decoder=${avc?.name} modes=$modes profiles=$profiles level=$level") }
        }

        private fun deviceName(context: Context): String =
            runCatching { Settings.Global.getString(context.contentResolver, "device_name") }.getOrNull()
                ?.takeIf { it.isNotBlank() }
                ?: runCatching { Settings.Secure.getString(context.contentResolver, "bluetooth_name") }.getOrNull()
                    ?.takeIf { it.isNotBlank() }
                ?: Build.MODEL

        /**
         * Probes the decoder for the native size first, then a ladder of common desktop sizes, and
         * records the highest frame rate each one supports. Uses measured performance points
         * (API 29+) when the codec publishes them, because claimed limits are often optimistic.
         * Never pairs the max width with the max height independently (that size may not exist).
         */
        private fun decodeModes(info: MediaCodecInfo, nativeW: Int, nativeH: Int): List<DecodeMode> {
            val caps = runCatching { info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).videoCapabilities }.getOrNull()
                ?: return listOf(DecodeMode(1920, 1080, 30))
            val points = if (Build.VERSION.SDK_INT >= 29) runCatching { caps.supportedPerformancePoints }.getOrNull().orEmpty() else emptyList()
            val ladder = listOf(
                nativeW to nativeH,
                3840 to 2400, 3840 to 2160, 2960 to 1848, 2880 to 1800, 2800 to 1752, 2560 to 1600, 2560 to 1440,
                2048 to 1536, 2000 to 1200, 1920 to 1200, 1920 to 1080, 1600 to 1000, 1280 to 800, 1280 to 720,
            ).distinct()
            fun supports(w: Int, h: Int, fps: Int): Boolean {
                val claimed = runCatching { caps.areSizeAndRateSupported(w, h, fps.toDouble()) || caps.areSizeAndRateSupported(h, w, fps.toDouble()) }
                    .getOrDefault(false)
                if (!claimed) return false
                if (Build.VERSION.SDK_INT >= 29 && points.isNotEmpty()) {
                    val want = MediaCodecInfo.VideoCapabilities.PerformancePoint(w, h, fps)
                    // Only 30+ fps is gated by measurements; tiny sizes may be missing from the list.
                    if (fps > 30 && points.none { it.covers(want) }) return false
                }
                return true
            }
            val out = ArrayList<DecodeMode>()
            for ((w, h) in ladder) {
                val sizeOk = runCatching { caps.isSizeSupported(w, h) || caps.isSizeSupported(h, w) }.getOrDefault(false)
                if (!sizeOk) continue
                val fps = listOf(120, 90, 60, 30).firstOrNull { supports(w, h, it) } ?: continue
                out.add(DecodeMode(w, h, fps))
            }
            if (out.isEmpty()) {
                // Joint fallback: the largest height actually supported for the largest width.
                val mw = runCatching { caps.supportedWidths.upper }.getOrDefault(1920)
                val mh = runCatching { caps.getSupportedHeightsFor(mw).upper }.getOrDefault(1080)
                out.add(DecodeMode(max(mw, mh), min(mw, mh), 30))
            }
            return out.sortedByDescending { it.width.toLong() * it.height }.take(8)
        }

        private fun profilesAndLevel(info: MediaCodecInfo): Pair<List<String>, String> {
            val pl = runCatching { info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).profileLevels }.getOrNull()
                ?: return emptyList<String>() to ""
            val profiles = LinkedHashSet<String>()
            var maxLevel = 0
            for (p in pl) {
                when (p.profile) {
                    CodecProfileLevel.AVCProfileHigh, CodecProfileLevel.AVCProfileConstrainedHigh -> profiles.add("high")
                    CodecProfileLevel.AVCProfileMain -> profiles.add("main")
                    CodecProfileLevel.AVCProfileBaseline, CodecProfileLevel.AVCProfileConstrainedBaseline -> profiles.add("baseline")
                }
                if (p.level > maxLevel) maxLevel = p.level
            }
            val ordered = listOf("high", "main", "baseline").filter { it in profiles }
            return ordered to levelName(maxLevel)
        }

        private fun levelName(level: Int): String = when {
            level >= CodecProfileLevel.AVCLevel62 -> "6.2"
            level >= CodecProfileLevel.AVCLevel61 -> "6.1"
            level >= CodecProfileLevel.AVCLevel6 -> "6"
            level >= CodecProfileLevel.AVCLevel52 -> "5.2"
            level >= CodecProfileLevel.AVCLevel51 -> "5.1"
            level >= CodecProfileLevel.AVCLevel5 -> "5"
            level >= CodecProfileLevel.AVCLevel42 -> "4.2"
            level >= CodecProfileLevel.AVCLevel41 -> "4.1"
            level >= CodecProfileLevel.AVCLevel4 -> "4"
            level >= CodecProfileLevel.AVCLevel32 -> "3.2"
            level >= CodecProfileLevel.AVCLevel31 -> "3.1"
            level >= CodecProfileLevel.AVCLevel3 -> "3"
            level > 0 -> "2"
            else -> ""
        }

        private fun hasStylus(): Boolean = InputDevice.getDeviceIds().any { id ->
            InputDevice.getDevice(id)?.supportsSource(InputDevice.SOURCE_STYLUS) == true
        }
    }
}
