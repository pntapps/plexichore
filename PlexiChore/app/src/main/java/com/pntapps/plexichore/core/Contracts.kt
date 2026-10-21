package com.pntapps.plexichore.core

import kotlinx.coroutines.flow.StateFlow

/*
 * Shared contract between the core (networking/decoding/input) layer and the UI layer.
 * Core agent implements [PlexiConnection]; UI agent consumes it. Do not change signatures
 * without updating both sides. Protocol details: ../../../../../../../../../PROTOCOL.md
 */

enum class Transport { USB, WIFI, MANUAL }

data class DiscoveredHost(
    val id: String,
    val name: String,
    val os: String,              // "windows" | "macos"
    val address: String,         // "127.0.0.1" for USB
    val port: Int = 47800,
    val transport: Transport,
    val virtualDisplay: Boolean,
    val lastSeenMs: Long,
    /** Additive: reached over the USB cable as a network link (Android USB tethering: rndis/ncm), not over Wi-Fi. */
    val usbNetwork: Boolean = false,
)

enum class DisplayMode { EXTEND, PRIMARY, MIRROR }
enum class Quality { PERFORMANCE, BALANCED, QUALITY }
enum class TouchMode { TOUCH, MOUSE, NONE }
enum class Position { RIGHT, LEFT, TOP, BOTTOM }

data class StreamSettings(
    val mode: DisplayMode = DisplayMode.EXTEND,
    val monitorIndex: Int = 0,
    val resolutionScale: Float = 1.0f,
    val fps: Int = 60,
    val bitrateKbps: Int = 20_000,
    val quality: Quality = Quality.BALANCED,
    val codec: String = "h264",
    val touchMode: TouchMode = TouchMode.TOUCH,
    val position: Position = Position.RIGHT,
    val keepScreenOn: Boolean = true,
    val showStatsOverlay: Boolean = false,
    /** Host display scale (Windows DPI) of the virtual monitor, extend/primary only. 0 = Auto, else 100..300. */
    val scalePercent: Int = 0,
    /** Additive: physical path as the host sees it: "usb-cable", "usb-wireless-adb" (adb reverse over wireless debugging), "wifi"; "" = unknown. */
    val link: String = "",
    /** Additive, local only: floating keyboard button on the stream screen. */
    val showKeyboardButton: Boolean = true,
)

sealed interface ConnectionState {
    data object Idle : ConnectionState
    data class Connecting(val host: DiscoveredHost) : ConnectionState
    data class AwaitingApproval(val host: DiscoveredHost, val code: String) : ConnectionState
    data class Streaming(val host: DiscoveredHost, val config: StreamConfig) : ConnectionState
    data class Failed(val host: DiscoveredHost?, val message: String) : ConnectionState
}

data class StreamConfig(
    val codec: String,
    val width: Int,
    val height: Int,
    val fps: Int,
    val bitrateKbps: Int,
    val mode: DisplayMode,
    val hostName: String,
    val hostOs: String,
    val virtualDisplayAvailable: Boolean,
    /** Display scale the host applied to the virtual monitor (percent); 0 = not applicable (mirror) / unknown. */
    val scalePercent: Int = 0,
    /** Additive: physical path as the host sees it: "usb-cable", "usb-wireless-adb" (adb reverse over wireless debugging), "wifi"; "" = unknown. */
    val link: String = "",
)

data class StreamStats(
    val fps: Float = 0f,
    val rttMs: Float = 0f,
    val bitrateKbps: Int = 0,
    val decodeMs: Float = 0f,
    val droppedFrames: Int = 0,
)

/** Process-wide singleton, obtain via `PlexiCore.get(context)` (implemented by core). */
interface PlexiConnection {
    val state: StateFlow<ConnectionState>
    val hosts: StateFlow<List<DiscoveredHost>>   // USB + Wi-Fi, pruned after ~4 s unseen
    val stats: StateFlow<StreamStats>

    fun startDiscovery()
    fun stopDiscovery()

    /** Connects and on success the core launches [com.pntapps.plexichore.display.DisplayActivity]. */
    fun connect(host: DiscoveredHost, settings: StreamSettings)
    fun connectManual(ip: String, port: Int = 47800, settings: StreamSettings)
    fun updateSettings(settings: StreamSettings)  // live, sends SETTINGS
    fun disconnect()

    /**
     * Additive: sends a KEY message (PROTOCOL.md 0x05) while streaming. [action] "down" | "up",
     * [keyCode] an Android `KeyEvent.KEYCODE_*`, [text] typed as Unicode by the host on "down" (keyCode ignored).
     */
    fun sendKey(action: String, keyCode: Int, text: String? = null) {}
}
