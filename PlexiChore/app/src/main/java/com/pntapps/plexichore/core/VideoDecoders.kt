package com.pntapps.plexichore.core

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Paint
import android.graphics.Rect
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.util.Log
import android.view.Surface
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** One VIDEO message. [data] is owned by the frame (never reused by the reader). */
internal class VideoFrame(
    val ptsUs: Long,
    val flags: Int,
    val data: ByteArray,
    val offset: Int,
    val length: Int,
) {
    val isKey: Boolean get() = flags and Protocol.VIDEO_FLAG_KEYFRAME != 0
    val isConfig: Boolean get() = flags and Protocol.VIDEO_FLAG_CODEC_CONFIG != 0
}

/** Callbacks from a decoder, invoked on the decoder's own thread. */
internal interface DecoderSink {
    fun onFrameRendered(decodeNanos: Long)
    fun onFramesDropped(count: Int)
    fun onKeyframeNeeded()
    fun onFatalError(decoder: FrameDecoder, error: Throwable)
}

internal interface FrameDecoder {
    /** Non-blocking; may be called from any thread, also after [release] (then it is a no-op). */
    fun submit(frame: VideoFrame)

    /** Synchronous; after it returns the decoder no longer touches its Surface. */
    fun release()
}

/**
 * Hardware H.264 decoder in asynchronous mode, rendering straight to the Surface.
 * Frames are queued the moment an input buffer is free; output buffers are rendered immediately.
 * If the decoder falls behind, the backlog is dropped and a keyframe is requested instead of
 * letting latency accumulate.
 */
internal class H264Decoder private constructor(
    private val codec: MediaCodec,
    private val thread: HandlerThread,
    private val sink: DecoderSink,
    /** MediaCodec name, so repeated runtime failures can move on to the next candidate. */
    val codecName: String,
) : FrameDecoder {

    /** Render-time de-jitter (set by [VideoPipeline]); null = render each frame as soon as it is decoded. */
    @Volatile var pacer: FramePacer? = null
    /** Largest size this instance accepts without being rebuilt (adaptive playback), 0x0 when not adaptive. */
    var adaptiveMaxWidth = 0
        private set
    var adaptiveMaxHeight = 0
        private set

    private val lock = Any()
    private val freeInputs = ArrayDeque<Int>()
    private val pending = ArrayDeque<VideoFrame>()
    private var awaitingKeyframe = true
    private var released = false
    private var seq = 0L
    private val enqueueNanos = LongArray(LATENCY_SLOTS)

    private val callback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(mc: MediaCodec, index: Int) {
            synchronized(lock) {
                if (released) return
                freeInputs.addLast(index)
                drainLocked()
            }
        }

        override fun onOutputBufferAvailable(mc: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            if (released) return
            try {
                val render = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM == 0
                val p = pacer
                if (render && p != null) mc.releaseOutputBuffer(index, p.renderTimeNs(System.nanoTime()))
                else mc.releaseOutputBuffer(index, render)
            } catch (e: IllegalStateException) {
                if (!released) sink.onFatalError(this@H264Decoder, e)
                return
            }
            if (info.flags and (MediaCodec.BUFFER_FLAG_CODEC_CONFIG or MediaCodec.BUFFER_FLAG_END_OF_STREAM) == 0) {
                val s = info.presentationTimeUs / PTS_STEP_US
                val t0 = enqueueNanos[(s % LATENCY_SLOTS).toInt()]
                sink.onFrameRendered(if (t0 > 0) System.nanoTime() - t0 else 0L)
            }
        }

        override fun onError(mc: MediaCodec, e: MediaCodec.CodecException) {
            if (released) return
            Log.w(TAG, "Decoder error transient=${e.isTransient} recoverable=${e.isRecoverable}", e)
            if (!e.isTransient) sink.onFatalError(this@H264Decoder, e)
        }

        override fun onOutputFormatChanged(mc: MediaCodec, format: MediaFormat) {
            Log.d(TAG, "Output format: $format")
        }
    }

    override fun submit(frame: VideoFrame) {
        synchronized(lock) {
            if (released) return
            // A buffer carrying parameter sets *and* slices is fed as a regular access unit.
            val configOnly = frame.isConfig && !containsSlice(frame)
            if (awaitingKeyframe && !configOnly && !frame.isKey) {
                sink.onFramesDropped(1)
                return
            }
            if (!configOnly && pending.count { !it.isConfigOnly() } >= MAX_PENDING) {
                // Decoder is behind: throw away the backlog (keep parameter sets) and resync.
                val before = pending.size
                val keep = pending.lastOrNull { it.isConfigOnly() }
                pending.clear()
                keep?.let { pending.addLast(it) }
                sink.onFramesDropped(before - pending.size)
                if (!frame.isKey) {
                    awaitingKeyframe = true
                    sink.onFramesDropped(1)
                    sink.onKeyframeNeeded()
                    return
                }
            }
            if (frame.isKey) awaitingKeyframe = false
            pending.addLast(frame)
            drainLocked()
        }
    }

    private fun VideoFrame.isConfigOnly() = isConfig && !containsSlice(this)

    private fun drainLocked() {
        try {
            while (freeInputs.isNotEmpty() && pending.isNotEmpty()) {
                val index = freeInputs.removeFirst()
                val f = pending.removeFirst()
                val buf = codec.getInputBuffer(index) ?: continue
                if (f.length > buf.capacity()) {
                    Log.w(TAG, "Access unit ${f.length} B exceeds input buffer ${buf.capacity()} B")
                    freeInputs.addFirst(index)
                    pending.clear()
                    awaitingKeyframe = true
                    sink.onFramesDropped(1)
                    sink.onKeyframeNeeded()
                    return
                }
                buf.clear()
                buf.put(f.data, f.offset, f.length)
                val configOnly = f.isConfigOnly()
                val flags = when {
                    configOnly -> MediaCodec.BUFFER_FLAG_CODEC_CONFIG
                    f.isKey -> MediaCodec.BUFFER_FLAG_KEY_FRAME
                    else -> 0
                }
                // Our own monotonic timestamps: host pts may repeat (re-sent frames).
                val s = seq++
                if (!configOnly) enqueueNanos[(s % LATENCY_SLOTS).toInt()] = System.nanoTime()
                codec.queueInputBuffer(index, 0, f.length, s * PTS_STEP_US, flags)
            }
        } catch (e: IllegalStateException) {
            if (!released) sink.onFatalError(this, e)
        }
    }

    override fun release() {
        synchronized(lock) {
            if (released) return
            released = true
            pending.clear()
            freeInputs.clear()
        }
        runCatching { codec.stop() }
        runCatching { codec.release() }
        thread.quitSafely()
    }

    companion object {
        private const val TAG = "PlexiH264"
        // Frames waiting for a free decoder input buffer before the backlog is dropped (and a keyframe awaited).
        // adb tunnels deliver 3-6 frames at once after a stall; decoding takes ~4-9 ms per frame, so such a burst
        // clears in well under a frame time each. Dropping at 3 threw away bursts *and* every frame up to the next
        // IDR (65-135 frames per phase over wireless adb). Only a backlog this deep means truly behind.
        private const val MAX_PENDING = 12
        private const val LATENCY_SLOTS = 64
        private const val PTS_STEP_US = 1_000L

        @Volatile private var cachedCandidates: List<MediaCodecInfo>? = null

        /** Decoders that could not be configured/started, or kept failing at runtime, in this process. */
        private val failedNames: MutableSet<String> = java.util.concurrent.ConcurrentHashMap.newKeySet()

        /**
         * Every usable AVC decoder, best first: hardware before software, then those advertising
         * FEATURE_LowLatency. Secure-only and alias entries are dropped. Software decoders
         * (c2.android.avc / OMX.google.h264.decoder) stay at the end as the last resort before MJPEG.
         */
        fun candidates(): List<MediaCodecInfo> {
            cachedCandidates?.let { return it }
            val all = runCatching {
                MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter {
                    !it.isEncoder &&
                        it.supportedTypes.any { t -> t.equals(MediaFormat.MIMETYPE_VIDEO_AVC, true) } &&
                        !it.name.contains("secure", true) &&
                        !(Build.VERSION.SDK_INT >= 29 && it.isAlias)
                }
            }.getOrDefault(emptyList())
            val ranked = all.sortedByDescending { info ->
                var score = 0
                if (isHardware(info)) score += 10
                if (supportsLowLatency(info)) score += 5
                score
            }
            if (ranked.isNotEmpty()) cachedCandidates = ranked
            Log.i(TAG, "AVC decoders: " + ranked.joinToString { it.name })
            return ranked
        }

        /** Best decoder that has not failed in this process (used for HELLO capabilities). */
        fun findDecoder(): MediaCodecInfo? = candidates().firstOrNull { it.name !in failedNames } ?: candidates().firstOrNull()

        /** True while at least one candidate other than [name] has not failed yet. */
        fun hasAlternativeTo(name: String): Boolean = candidates().any { it.name != name && it.name !in failedNames }

        fun markFailed(name: String) {
            if (failedNames.add(name)) Log.w(TAG, "Decoder $name marked as failed; next: ${findDecoder()?.name}")
        }

        fun supportsAdaptive(info: MediaCodecInfo): Boolean = runCatching {
            info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
                .isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_AdaptivePlayback)
        }.getOrDefault(false)

        fun supportsLowLatency(info: MediaCodecInfo): Boolean =
            Build.VERSION.SDK_INT >= 30 && runCatching {
                info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
                    .isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
            }.getOrDefault(false)

        private fun isHardware(info: MediaCodecInfo): Boolean =
            if (Build.VERSION.SDK_INT >= 29) info.isHardwareAccelerated
            else {
                val n = info.name.lowercase()
                !n.startsWith("omx.google.") && !n.startsWith("c2.android.") && !n.contains(".sw.") && !n.startsWith("omx.ffmpeg")
            }

        private fun sizeSupported(info: MediaCodecInfo, w: Int, h: Int): Boolean = runCatching {
            val vc = info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).videoCapabilities
            vc == null || vc.isSizeSupported(w, h) || vc.isSizeSupported(h, w)
        }.getOrDefault(true)

        /**
         * Tries every candidate in order and, per candidate, progressively simpler formats:
         * full low-latency → no vendor keys / no operating rate → basic. Only when all fail the
         * caller falls back to MJPEG.
         */
        fun create(surface: Surface, width: Int, height: Int, fps: Int, sink: DecoderSink, maxWidth: Int = 0, maxHeight: Int = 0): H264Decoder {
            val pool = candidates().filter { it.name !in failedNames }.ifEmpty { candidates() }
            if (pool.isEmpty()) throw IllegalStateException("No H.264 decoder on this device")
            // Decoders that do not claim this size go last instead of being skipped (claims are often conservative).
            val ordered = pool.sortedBy { if (sizeSupported(it, width, height)) 0 else 1 }
            var last: Throwable? = null
            for (info in ordered) {
                try {
                    return createWith(info, surface, width, height, fps, sink, maxWidth, maxHeight)
                } catch (t: Throwable) {
                    last = t
                    Log.w(TAG, "Decoder ${info.name} unusable for ${width}x$height@$fps: ${t.message}")
                    markFailed(info.name)
                }
            }
            throw last ?: IllegalStateException("No usable H.264 decoder")
        }

        private fun createWith(info: MediaCodecInfo, surface: Surface, width: Int, height: Int, fps: Int, sink: DecoderSink, maxWidth: Int = 0, maxHeight: Int = 0): H264Decoder {
            val thread = HandlerThread("plexi-h264", Process.THREAD_PRIORITY_URGENT_DISPLAY).apply { start() }
            var codec: MediaCodec? = null
            try {
                codec = MediaCodec.createByCodecName(info.name)
                val decoder = H264Decoder(codec, thread, sink, info.name)
                val handler = Handler(thread.looper)
                val vendorKeys = supportedVendorKeys(codec)
                val lowLatency = supportsLowLatency(info)
                // adaptive playback: the host may change the encode size mid-stream (adaptive resolution); a decoder
                // configured for the largest size takes the new SPS + IDR without being rebuilt
                val adaptive = maxWidth > 0 && maxWidth >= width && maxHeight >= height && supportsAdaptive(info)
                val formats = listOf(
                    "low-latency" to lowLatencyFormat(info.name, width, height, fps, lowLatency, vendorKeys, rateHints = true).apply {
                        if (adaptive) { setInteger(MediaFormat.KEY_MAX_WIDTH, maxWidth); setInteger(MediaFormat.KEY_MAX_HEIGHT, maxHeight) }
                    },
                    "no vendor keys" to lowLatencyFormat(info.name, width, height, fps, lowLatency, vendorKeys = emptySet(), rateHints = false),
                    "basic" to basicFormat(width, height),
                )
                var configured = false
                var configuredWith = -1
                for ((i, f) in formats.withIndex()) {
                    try {
                        if (i > 0) codec.reset()
                        codec.setCallback(decoder.callback, handler)
                        codec.configure(f.second, surface, null, 0)
                        configured = true
                        configuredWith = i
                        if (i > 0) Log.i(TAG, "${info.name} configured with ${f.first} format")
                        break
                    } catch (e: Exception) {
                        Log.w(TAG, "${info.name}: ${f.first} configure failed: ${e.message}")
                        if (i == formats.lastIndex) throw e
                    }
                }
                check(configured)
                codec.start()
                if (adaptive && configuredWith == 0) { decoder.adaptiveMaxWidth = maxWidth; decoder.adaptiveMaxHeight = maxHeight }
                Log.i(TAG, "Started ${info.name} ${width}x$height@$fps lowLatency=$lowLatency vendorKeys=${vendorKeys?.size ?: "n/a"} adaptiveMax=${decoder.adaptiveMaxWidth}x${decoder.adaptiveMaxHeight}")
                return decoder
            } catch (t: Throwable) {
                codec?.let { runCatching { it.release() } }
                thread.quitSafely()
                throw t
            }
        }

        /** Vendor parameter names this codec declares (API 31+); null below 31 = unknown, use the name heuristics. */
        private fun supportedVendorKeys(codec: MediaCodec): Set<String>? =
            if (Build.VERSION.SDK_INT >= 31) runCatching { codec.supportedVendorParameters.toSet() }.getOrNull() else null

        private fun basicFormat(width: Int, height: Int): MediaFormat =
            MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, maxOf(width * height, 1 shl 20))
            }

        private fun lowLatencyFormat(
            name: String, width: Int, height: Int, fps: Int,
            lowLatency: Boolean, vendorKeys: Set<String>?, rateHints: Boolean,
        ): MediaFormat =
            basicFormat(width, height).apply {
                // Only where the codec advertises it: some c2 HALs fail configure() on unknown keys.
                if (lowLatency && Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                setInteger(MediaFormat.KEY_PRIORITY, 0) // realtime
                setInteger(MediaFormat.KEY_FRAME_RATE, fps.coerceIn(1, 240))
                // Some API 26-28 OMX decoders reject an absurd operating rate; it is dropped in the 2nd attempt.
                if (rateHints) setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
                fun vendor(key: String, value: Int) {
                    // API 31+: only keys the codec declares (names are listed without or with the "vendor." prefix).
                    if (vendorKeys == null || key in vendorKeys || key.removePrefix("vendor.") in vendorKeys) setInteger(key, value)
                }
                val n = name.lowercase()
                if (vendorKeys?.isEmpty() == true && !rateHints) return@apply
                if (n.startsWith("c2.qti") || n.startsWith("omx.qcom")) {
                    vendor("vendor.qti-ext-dec-low-latency.enable", 1)
                    vendor("vendor.qti-ext-dec-picture-order.enable", 1)
                }
                if (n.startsWith("c2.exynos") || n.startsWith("omx.exynos")) {
                    vendor("vendor.rtc-ext-dec-low-latency.enable", 1)
                }
                if (n.startsWith("c2.mtk") || n.startsWith("omx.mtk")) {
                    vendor("vendor.mtk.vdec.lowlatency.mode", 1)
                    if (n.startsWith("omx.mtk")) setInteger("vdec-lowlatency", 1) // OMX-era key, harmless elsewhere
                }
            }

        /** True if the Annex-B buffer contains a coded slice (NAL 1 or 5), scanning a few NALs only. */
        fun containsSlice(f: VideoFrame): Boolean {
            val d = f.data
            val end = f.offset + f.length
            var i = f.offset
            var nals = 0
            while (i + 3 < end && nals < 8) {
                if (d[i].toInt() == 0 && d[i + 1].toInt() == 0 &&
                    (d[i + 2].toInt() == 1 || (d[i + 2].toInt() == 0 && i + 4 < end && d[i + 3].toInt() == 1))
                ) {
                    val hdr = if (d[i + 2].toInt() == 1) i + 3 else i + 4
                    if (hdr >= end) return false
                    val type = d[hdr].toInt() and 0x1F
                    if (type == 1 || type == 5) return true
                    nals++
                    i = hdr + 1
                } else i++
            }
            return false
        }
    }
}

/**
 * MJPEG fallback: decodes each JPEG into a reused Bitmap and blits it with a hardware canvas.
 * Only the newest frame is kept; frames that arrive while one is decoding replace it (dropped).
 */
internal class MjpegDecoder(
    private val surface: Surface,
    private val sink: DecoderSink,
) : FrameDecoder {

    private val thread = HandlerThread("plexi-mjpeg", Process.THREAD_PRIORITY_URGENT_DISPLAY).apply { start() }
    private val handler = Handler(thread.looper)
    private val latest = AtomicReference<VideoFrame?>(null)
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val dst = Rect()
    private val options = BitmapFactory.Options().apply {
        inMutable = true
        inPreferredConfig = Bitmap.Config.ARGB_8888
    }
    private var bitmap: Bitmap? = null

    @Volatile private var released = false

    private val decodeTask = Runnable { decodeLatest() }

    override fun submit(frame: VideoFrame) {
        if (released) return
        if (latest.getAndSet(frame) != null) sink.onFramesDropped(1) else handler.post(decodeTask)
    }

    private fun decodeLatest() {
        val f = latest.getAndSet(null) ?: return
        if (released) return
        val t0 = System.nanoTime()
        val bmp = try {
            options.inBitmap = bitmap
            BitmapFactory.decodeByteArray(f.data, f.offset, f.length, options)
        } catch (_: IllegalArgumentException) {
            // Reused bitmap incompatible (size changed): decode into a fresh one.
            options.inBitmap = null
            BitmapFactory.decodeByteArray(f.data, f.offset, f.length, options)
        }
        if (bmp == null) {
            sink.onFramesDropped(1)
            return
        }
        if (bmp !== bitmap) {
            bitmap?.recycle()
            bitmap = bmp
        }
        try {
            if (released || !surface.isValid) return
            val canvas = surface.lockHardwareCanvas()
            try {
                dst.set(0, 0, canvas.width, canvas.height)
                canvas.drawBitmap(bmp, null, dst, paint)
            } finally {
                surface.unlockCanvasAndPost(canvas)
            }
            sink.onFrameRendered(System.nanoTime() - t0)
        } catch (e: Exception) {
            if (!released) sink.onFatalError(this, e)
        }
    }

    override fun release() {
        if (released) return
        released = true
        latest.set(null)
        handler.removeCallbacksAndMessages(null)
        // Wait for an in-flight draw so nobody touches the Surface after we return.
        val done = CountDownLatch(1)
        handler.post {
            bitmap?.recycle()
            bitmap = null
            done.countDown()
        }
        thread.quitSafely()
        done.await(500, TimeUnit.MILLISECONDS)
    }
}
