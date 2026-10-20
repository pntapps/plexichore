package com.pntapps.plexichore.core

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Choreographer
import kotlin.math.max

/**
 * The display's present grid as SurfaceFlinger sees it: one expected presentation time and the vsync period,
 * re-sampled about once a second from Choreographer's frame timelines (API 33+; older releases: unknown -> the
 * pacer works without vsync alignment). Process-wide: there is one panel.
 */
internal object VsyncClock {
    @Volatile var refNs = 0L
        private set
    @Volatile var periodNs = 0L
        private set
    @Volatile private var sampledAtMs = 0L

    private val main = Handler(Looper.getMainLooper())
    @Volatile private var users = 0

    /** Valid when sampled within the last 3 s. */
    fun valid(): Boolean = periodNs in 2_000_000L..50_000_000L && SystemClock.uptimeMillis() - sampledAtMs < 3_000

    /** First present time at or after [t] (t itself when the grid is unknown). */
    fun presentAtOrAfter(t: Long): Long {
        val p = periodNs
        if (!valid()) return t
        val k = Math.floorDiv(t - refNs + p - 1, p)
        return refNs + k * p
    }

    private val sampler = object : Runnable {
        override fun run() {
            if (users <= 0) return
            sample()
            main.postDelayed(this, 1_000)
        }
    }

    fun start() {
        if (Build.VERSION.SDK_INT < 33) return
        main.post {
            users++
            if (users == 1) main.post(sampler)
        }
    }

    fun stop() {
        if (Build.VERSION.SDK_INT < 33) return
        main.post { users = (users - 1).coerceAtLeast(0) }
    }

    private fun sample() {
        if (Build.VERSION.SDK_INT < 33) return
        runCatching {
            Choreographer.getInstance().postVsyncCallback { d ->
                val tl = d.frameTimelines
                val p0 = tl[0].expectedPresentationTimeNanos
                if (tl.size > 1) {
                    publish(p0, tl[1].expectedPresentationTimeNanos - p0)
                } else {
                    // one timeline only: measure the period from the next vsync
                    Choreographer.getInstance().postVsyncCallback { d2 ->
                        val p1 = d2.frameTimelines[0].expectedPresentationTimeNanos
                        publish(p1, p1 - p0)
                    }
                }
            }
        }
    }

    private fun publish(ref: Long, period: Long) {
        if (period !in 2_000_000L..50_000_000L) return
        refNs = ref
        periodNs = period
        sampledAtMs = SystemClock.uptimeMillis()
    }
}

/**
 * Adaptive de-jitter for decoded frames: picks the render timestamp passed to
 * `MediaCodec.releaseOutputBuffer(index, renderTimestampNs)` (System.nanoTime() base; SurfaceFlinger presents the
 * buffer at the first vsync whose expected present time is at or after it).
 *
 * A small playout clock: each frame gets the present slot one frame interval after the previous one, but never
 * earlier than its own arrival. Frames that arrive evenly (Wi-Fi direct) are shown at once - no added latency. When
 * the link delivers frames in bursts (adb reverse over USB / wireless debugging bunches frames after 50-200 ms
 * gaps), the frames of a burst are spread over consecutive slots instead of reaching SurfaceFlinger together (where
 * all but the newest would be dropped in one vsync), and a playout delay of 0..[MAX_DELAY_FRAMES] frame intervals -
 * sized from the stalls actually seen in the last ~3 s, and only from stalls followed by a burst (an irregular but
 * un-bunched host frame rate gains nothing from buffering) - absorbs the next gap. It decays by itself when the
 * link calms down. Latency is bounded: never more than delay + half a frame ahead of now.
 *
 * With the present grid known ([VsyncClock]) slots are whole vsyncs and each timestamp sits half a vsync before its
 * target vsync, so arrival jitter does not flip a frame between two vsyncs: 60 fps on a 120 Hz panel is a steady
 * 2 vsyncs per frame, the host's 40 fps fallback a steady 3.
 *
 * Called from the decoder's callback thread only.
 */
internal class FramePacer(fps: Int) {
    private val periodNs = 1_000_000_000L / fps.coerceIn(1, 240)

    private var lastPresentNs = 0L      // present slot of the previous frame
    private var lastArrivalNs = 0L
    private var pendingLateNs = 0L      // stall seen on the previous frame, confirmed if a bunched frame follows
    private var pendingFrames = 0

    /** Current playout delay (ns). */
    @Volatile var delayNs = 0L
        private set

    // confirmed stall sizes over ~3 s, in 0.5 s buckets (max per bucket)
    private val window = LongArray(6)
    private var bucketStartNs = 0L
    private var bucket = 0

    fun reset() {
        lastPresentNs = 0L
        lastArrivalNs = 0L
        pendingLateNs = 0L
        pendingFrames = 0
    }

    // How long before a vsync a buffer must be queued to be shown at it (SurfaceFlinger's latch deadline). Measured on
    // a Tab S8 (120 Hz) from SurfaceFlinger's desired vs actual present times: 0.25 vsync lead -> ~35 % of frames a
    // vsync late, 4 ms -> 4 %, 9 ms -> 1 %, 13 ms -> 0 %. 0.85 vsync (~7 ms at 120 Hz) keeps misses near 1 % for about
    // the latency of an unpaced frame. (MediaCodec's frame-rendered times did not show these misses, so the lead is not
    // learned from them.)
    @Volatile var leadNs = -1L
        private set

    /** Render timestamp for a frame whose decoded output is available at [nowNs]. */
    fun renderTimeNs(nowNs: Long): Long {
        roll(nowNs)
        val grid = VsyncClock.valid()
        val vp = if (grid) VsyncClock.periodNs else 0L
        if (grid) leadNs = if (LEAD_OVERRIDE_NS > 0) LEAD_OVERRIDE_NS else vp * 85 / 100
        // frame interval in whole vsyncs when the grid is known (16.7 ms -> 2 x 8.33, 25 ms -> 3 x 8.33)
        val step = if (grid) max(1L, (periodNs + vp / 2) / vp) * vp else periodNs
        // the earliest present this frame can still make
        val earliest = if (grid) VsyncClock.presentAtOrAfter(nowNs + leadNs) else nowNs
        return schedule(nowNs, grid, vp, step, earliest)
    }
    private fun schedule(nowNs: Long, grid: Boolean, vp: Long, step: Long, earliest: Long): Long {

        val gap = nowNs - lastArrivalNs
        val idle = lastArrivalNs == 0L || gap > periodNs * 6
        lastArrivalNs = nowNs
        val present: Long
        if (idle) {
            pendingLateNs = 0L
            present = if (grid) VsyncClock.presentAtOrAfter(earliest + delayNs) else earliest + delayNs
        } else {
            // a bunched arrival right after a stall proves the stall was the link, not the content
            if (gap < periodNs / 2 && pendingLateNs > 0) {
                if (pendingLateNs > window[bucket]) window[bucket] = pendingLateNs
                pendingLateNs = 0L
            } else if (--pendingFrames <= 0) pendingLateNs = 0L

            val slot = lastPresentNs + step
            if (earliest > slot) {
                // underrun: late for its slot -> re-anchor with the cushion
                pendingLateNs = earliest - slot
                pendingFrames = 2
                present = if (grid) VsyncClock.presentAtOrAfter(earliest + delayNs) else earliest + delayNs
            } else {
                // bound the latency the clock may accumulate (host clock a bit fast, delay just shrank)
                val cap = earliest + delayNs + periodNs / 2
                present = if (slot > cap) (if (grid) VsyncClock.presentAtOrAfter(cap - vp + 1) else cap) else slot
            }
        }
        lastPresentNs = present
        // half a vsync early: robust against jitter on both sides of the target vsync; never in the past
        return if (grid) max(nowNs, present - vp / 2) else present
    }

    private fun roll(nowNs: Long) {
        if (bucketStartNs == 0L) bucketStartNs = nowNs
        var steps = 0
        while (nowNs - bucketStartNs >= BUCKET_NS && steps < window.size) {
            bucketStartNs += BUCKET_NS
            bucket = (bucket + 1) % window.size
            window[bucket] = 0L
            adapt()
            steps++
        }
        if (nowNs - bucketStartNs >= BUCKET_NS) bucketStartNs = nowNs
    }

    /** Delay from the 2nd-largest confirmed stall of the last ~3 s (one isolated spike does not add latency). */
    private fun adapt() {
        val want = window.sortedDescending()[1]
        val target = when {
            want < periodNs / 3 -> 0L
            want < periodNs * 3 / 2 -> periodNs
            else -> MAX_DELAY_FRAMES * periodNs
        }
        // grow at once, shrink gently
        delayNs = if (target >= delayNs) target else max(target, delayNs - periodNs / 2)
    }

    companion object {
        const val MAX_DELAY_FRAMES = 2L
        private const val BUCKET_NS = 500_000_000L
        /** Experiments: `adb shell setprop debug.plexichore.lead_us 11000` fixes the latch lead. */
        private val LEAD_OVERRIDE_NS: Long = runCatching {
            @Suppress("PrivateApi")
            val sp = Class.forName("android.os.SystemProperties").getMethod("get", String::class.java, String::class.java)
            (sp.invoke(null, "debug.plexichore.lead_us", "0") as String).toLong() * 1000
        }.getOrDefault(0L)
    }
}
