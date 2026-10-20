package com.pntapps.plexichore.core

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Owns the active decoder and rebuilds it whenever the output Surface or the stream
 * configuration (codec / size) changes. Thread-safe: the Surface is attached from the main
 * thread, frames arrive from the socket reader, decoder callbacks from decoder threads.
 */
internal class VideoPipeline(private val listener: Listener) {

    interface Listener {
        fun requestKeyframe()
        /** The decoder for [codec] cannot run on this device; caller may fall back to MJPEG. */
        fun onCodecUnavailable(codec: String)
    }

    private val lock = Any()
    private val main = Handler(Looper.getMainLooper())
    private var surface: Surface? = null
    private var config: StreamConfig? = null
    private var decoder: FrameDecoder? = null
    private var lastCodecConfig: VideoFrame? = null
    private val recentResets = ArrayDeque<Long>()

    // Counters consumed by the stats ticker.
    val rendered = AtomicInteger()
    val dropped = AtomicInteger()
    val decodeNanos = AtomicLong()

    /** Longest gap between two rendered frames since the last [takeMaxGapNanos] (smoothness metric). */
    private val maxGapNanos = AtomicLong()
    /** Frames that came > 1.5 frame intervals after the previous one while frames were flowing (visible hitches). */
    val hitches = AtomicInteger()
    @Volatile private var lastRenderNanos = 0L
    @Volatile private var frameIntervalNanos = 16_666_667L
    /** Called once when the first frame of a (re)configured stream is on screen. */
    @Volatile var onFirstFrame: (() -> Unit)? = null
    @Volatile private var firstFramePending = false

    fun takeMaxGapNanos(): Long = maxGapNanos.getAndSet(0)

    private val sink = object : DecoderSink {
        override fun onFrameRendered(decodeNanos: Long) {
            rendered.incrementAndGet()
            this@VideoPipeline.decodeNanos.addAndGet(decodeNanos)
            val now = System.nanoTime()
            val last = lastRenderNanos
            lastRenderNanos = now
            if (last != 0L) {
                val gap = now - last
                if (gap > maxGapNanos.get()) maxGapNanos.set(gap)
                // gaps over ~250 ms are an idle desktop, not a hitch
                if (gap > frameIntervalNanos * 3 / 2 && gap < 250_000_000L) hitches.incrementAndGet()
            }
            if (firstFramePending) {
                firstFramePending = false
                onFirstFrame?.invoke()
            }
        }

        override fun onFramesDropped(count: Int) {
            dropped.addAndGet(count)
        }

        override fun onKeyframeNeeded() = listener.requestKeyframe()

        override fun onFatalError(decoder: FrameDecoder, error: Throwable) {
            Log.w(TAG, "Decoder failed, rebuilding", error)
            main.post { resetIfCurrent(decoder) }
        }
    }

    fun setSurface(newSurface: Surface?) {
        synchronized(lock) {
            if (surface === newSurface) return
            releaseDecoderLocked()
            surface = newSurface
            // Keep the panel at its high refresh rate: with paced (timestamped) frames SurfaceFlinger otherwise
            // detects "60 fps video" and drops a 120 Hz panel to 60 Hz, where a frame that misses its vsync by 1 ms
            // shows for 33 ms instead of 25 ms.
            if (newSurface != null && android.os.Build.VERSION.SDK_INT >= 30) {
                runCatching { newSurface.setFrameRate(HIGH_REFRESH_HZ, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT) }
            }
            buildLocked()
        }
    }

    /** Detaches [old] only if it is still the active Surface (a newer view may already own it). */
    fun clearSurface(old: Surface) {
        synchronized(lock) {
            if (surface === old) setSurface(null)
        }
    }

    fun setConfig(newConfig: StreamConfig?) {
        synchronized(lock) {
            val old = config
            config = newConfig
            val same = old != null && newConfig != null && old.codec == newConfig.codec &&
                old.width == newConfig.width && old.height == newConfig.height
            if (same) {
                if (old!!.fps != newConfig!!.fps) (decoder as? H264Decoder)?.let { applyPacing(it, newConfig) }
                return
            }
            // Adaptive encode size on the host (same stream, smaller/larger frames): an adaptive-playback decoder
            // configured for the largest size just takes the new SPS + IDR, no rebuild (~0 vs 100-400 ms of black).
            val d = decoder as? H264Decoder
            if (old != null && newConfig != null && d != null && old.codec == newConfig.codec && newConfig.codec != CODEC_MJPEG &&
                newConfig.width <= d.adaptiveMaxWidth && newConfig.height <= d.adaptiveMaxHeight
            ) {
                Log.i(TAG, "Stream size ${old.width}x${old.height} -> ${newConfig.width}x${newConfig.height}: keeping the decoder (adaptive)")
                lastCodecConfig = null
                frameIntervalNanos = 1_000_000_000L / newConfig.fps.coerceIn(1, 240)
                applyPacing(d, newConfig)
                listener.requestKeyframe()
                return
            }
            lastCodecConfig = null
            releaseDecoderLocked()
            buildLocked()
        }
    }

    /** Current playout delay of the frame pacer (ms), for stats. */
    fun pacingDelayMs(): Float = ((decoder as? H264Decoder)?.pacer?.delayNs ?: 0L) / 1e6f

    /** Pacer latch lead (ms), -1 = present grid unknown (no vsync alignment), for stats. */
    fun pacingLeadMs(): Float = (decoder as? H264Decoder)?.pacer?.let { if (it.leadNs < 0) -1f else it.leadNs / 1e6f } ?: -1f

    private fun applyPacing(d: H264Decoder, c: StreamConfig) {
        d.pacer = if (PACING_ENABLED) FramePacer(c.fps) else null
        if (PACING_ENABLED && !vsyncSampling) { vsyncSampling = true; VsyncClock.start() }
    }

    /** Largest frame the tablet's panel shows (oriented like [c]); decoders are sized for it so size changes are free. */
    private fun adaptiveMax(c: StreamConfig): Pair<Int, Int> {
        val m = android.content.res.Resources.getSystem().displayMetrics
        val long = maxOf(m.widthPixels, m.heightPixels)
        val short = minOf(m.widthPixels, m.heightPixels)
        val (pw, ph) = if (c.width >= c.height) long to short else short to long
        return maxOf(pw, c.width) to maxOf(ph, c.height)
    }

    fun submit(frame: VideoFrame) {
        val d: FrameDecoder?
        synchronized(lock) {
            if (frame.isConfig && config?.codec != CODEC_MJPEG) lastCodecConfig = frame
            d = decoder
        }
        d?.submit(frame)
    }

    fun release() {
        synchronized(lock) {
            releaseDecoderLocked()
            surface = null
            config = null
            lastCodecConfig = null
        }
    }

    private fun resetIfCurrent(failed: FrameDecoder) {
        synchronized(lock) {
            if (decoder !== failed) return
            val now = SystemClock.elapsedRealtime()
            recentResets.addLast(now)
            while (recentResets.isNotEmpty() && now - recentResets.first() > 10_000) recentResets.removeFirst()
            releaseDecoderLocked()
            val codec = config?.codec
            if (recentResets.size > MAX_RESETS && codec != null && codec != CODEC_MJPEG) {
                recentResets.clear()
                // This decoder keeps failing: try the next one (other vendor component or the software
                // decoder) before giving up on H.264 altogether.
                val name = (failed as? H264Decoder)?.codecName
                if (name != null && H264Decoder.hasAlternativeTo(name)) {
                    H264Decoder.markFailed(name)
                    buildLocked()
                    return
                }
                listener.onCodecUnavailable(codec)
                return
            }
            buildLocked()
        }
    }

    private fun releaseDecoderLocked() {
        decoder?.let { runCatching { it.release() } }
        decoder = null
        if (vsyncSampling) { vsyncSampling = false; VsyncClock.stop() }
    }

    /** The pacer aligns frames to the panel's present grid while a paced decoder exists. */
    private var vsyncSampling = false

    private fun buildLocked() {
        val s = surface ?: return
        val c = config ?: return
        if (!s.isValid || c.width <= 0 || c.height <= 0) return
        frameIntervalNanos = 1_000_000_000L / c.fps.coerceIn(1, 240)
        lastRenderNanos = 0L
        firstFramePending = true
        decoder = try {
            if (c.codec == CODEC_MJPEG) MjpegDecoder(s, sink)
            else {
                val (mw, mh) = adaptiveMax(c)
                H264Decoder.create(s, c.width, c.height, c.fps, sink, mw, mh).also { applyPacing(it, c) }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "Cannot create ${c.codec} decoder", t)
            if (c.codec != CODEC_MJPEG) listener.onCodecUnavailable(c.codec)
            null
        }
        if (decoder != null && c.codec != CODEC_MJPEG) {
            lastCodecConfig?.let { decoder?.submit(it) }
            listener.requestKeyframe()
        }
    }

    companion object {
        private const val TAG = "PlexiVideo"
        private const val MAX_RESETS = 5
        private const val HIGH_REFRESH_HZ = 120f
        /** Render-time de-jitter for H.264 (see [FramePacer]); `adb shell setprop debug.plexichore.nopacing 1` disables it. */
        private val PACING_ENABLED: Boolean = runCatching {
            @Suppress("PrivateApi")
            val sp = Class.forName("android.os.SystemProperties").getMethod("get", String::class.java, String::class.java)
            sp.invoke(null, "debug.plexichore.nopacing", "0") != "1"
        }.getOrDefault(true)
        const val CODEC_MJPEG = "mjpeg"
    }
}
