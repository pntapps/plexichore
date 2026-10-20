package com.pntapps.plexichore.core

import org.json.JSONArray
import org.json.JSONObject
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Wire constants and (de)serialization for PlexiChore protocol v1. See PROTOCOL.md. */
internal object Protocol {
    const val VERSION = 1
    const val TCP_PORT = 47800
    const val UDP_PORT = 47801
    const val MAX_PAYLOAD = 16 * 1024 * 1024
    const val HEADER_SIZE = 5
    const val PROBE = "PLEXI?"

    const val HELLO: Int = 0x01
    const val CONFIG: Int = 0x02
    const val VIDEO: Int = 0x03
    const val INPUT: Int = 0x04
    const val KEY: Int = 0x05
    const val PING: Int = 0x06
    const val PONG: Int = 0x07
    const val REQUEST_KEYFRAME: Int = 0x08
    const val SETTINGS: Int = 0x09
    const val BYE: Int = 0x0A
    const val STATS: Int = 0x0B
    const val PAIRING: Int = 0x0C

    const val VIDEO_FLAG_KEYFRAME = 0x01
    const val VIDEO_FLAG_CODEC_CONFIG = 0x02

    /** Builds a complete frame (header + payload) ready to be written to the socket. */
    fun frame(type: Int, payload: ByteArray = EMPTY): ByteArray {
        val out = ByteArray(HEADER_SIZE + payload.size)
        out[0] = type.toByte()
        out[1] = (payload.size ushr 24).toByte()
        out[2] = (payload.size ushr 16).toByte()
        out[3] = (payload.size ushr 8).toByte()
        out[4] = payload.size.toByte()
        System.arraycopy(payload, 0, out, HEADER_SIZE, payload.size)
        return out
    }

    fun frame(type: Int, json: JSONObject): ByteArray = frame(type, json.toString().toByteArray(Charsets.UTF_8))

    fun pingFrame(timeMicros: Long): ByteArray =
        frame(PING, ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN).putLong(timeMicros).array())

    fun byeFrame(reason: String): ByteArray = frame(BYE, reason.toByteArray(Charsets.UTF_8))

    val EMPTY = ByteArray(0)

    /**
     * [orientation] (additive): "landscape" | "portrait" — how the tablet is held right now. Hosts that
     * know it build a portrait virtual display for "portrait"; older hosts ignore it.
     */
    fun requested(s: StreamSettings, codec: String, orientation: String = ORIENTATION_LANDSCAPE): JSONObject = JSONObject()
        .put("mode", s.mode.name.lowercase())
        .put("monitorIndex", s.monitorIndex)
        .put("resolutionScale", s.resolutionScale.coerceIn(0.5f, 1.0f).toDouble())
        .put("fps", s.fps)
        .put("bitrateKbps", s.bitrateKbps)
        .put("quality", s.quality.name.lowercase())
        .put("codec", codec)
        .put("touchMode", s.touchMode.name.lowercase())
        .put("position", s.position.name.lowercase())
        .put("scalePercent", s.scalePercent.coerceAtLeast(0))
        .put("orientation", orientation)

    fun hello(
        profile: DeviceProfile,
        settings: StreamSettings,
        codec: String,
        orientation: String = ORIENTATION_LANDSCAPE,
        viewport: Pair<Int, Int>? = null,
    ): JSONObject = JSONObject()
        .put("protocol", VERSION)
        .put("deviceId", profile.deviceId)
        .put("deviceName", profile.deviceName)
        .put("model", profile.model)
        .put("widthPx", profile.widthPx)
        .put("heightPx", profile.heightPx)
        .put("densityDpi", profile.densityDpi)
        .put("refreshHz", profile.refreshHz)
        .put("codecs", JSONArray(profile.codecs))
        .put("maxDecodeWidth", profile.maxDecodeWidth)
        .put("maxDecodeHeight", profile.maxDecodeHeight)
        // Additive decode capabilities: the host must not exceed any of them.
        .put("decodeModes", JSONArray(profile.decodeModes.map { JSONObject().put("width", it.width).put("height", it.height).put("maxFps", it.maxFps) }))
        .put("h264Profiles", JSONArray(profile.h264Profiles))
        .put("h264MaxLevel", profile.h264MaxLevel)
        .put("orientation", orientation)
        .apply { viewport?.let { (w, h) -> put("viewportWidthPx", w).put("viewportHeightPx", h) } }
        .put("touch", true)
        .put("pen", profile.hasStylus)
        .put("requested", requested(settings, codec, orientation))

    const val ORIENTATION_LANDSCAPE = "landscape"
    const val ORIENTATION_PORTRAIT = "portrait"

    fun parseConfig(json: JSONObject, fallbackHost: DiscoveredHost): StreamConfig = StreamConfig(
        codec = json.optString("codec", "h264").lowercase(),
        width = json.optInt("width", 0),
        height = json.optInt("height", 0),
        fps = json.optInt("fps", 60),
        bitrateKbps = json.optInt("bitrateKbps", 0),
        mode = when (json.optString("mode", "extend").lowercase()) { "mirror" -> DisplayMode.MIRROR; "primary" -> DisplayMode.PRIMARY; else -> DisplayMode.EXTEND },
        hostName = json.optString("hostName", fallbackHost.name).ifBlank { fallbackHost.name },
        hostOs = json.optString("hostOs", fallbackHost.os).ifBlank { fallbackHost.os },
        virtualDisplayAvailable = json.optBoolean("virtualDisplayAvailable", fallbackHost.virtualDisplay),
        scalePercent = json.optInt("scalePercent", 0),
        link = json.optString("link", ""),
    )

    fun readLong(b: ByteArray, off: Int): Long {
        var v = 0L
        for (i in 0 until 8) v = (v shl 8) or (b[off + i].toLong() and 0xFF)
        return v
    }

    @Throws(IOException::class)
    fun skipFully(input: DataInputStream, n: Int) {
        var left = n
        while (left > 0) {
            val s = input.skipBytes(left)
            if (s <= 0) {
                if (input.read() < 0) throw EOFException()
                left--
            } else left -= s
        }
    }
}
