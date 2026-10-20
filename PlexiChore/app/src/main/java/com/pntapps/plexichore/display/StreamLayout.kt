package com.pntapps.plexichore.display

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.PointF
import android.graphics.RectF
import android.util.SparseArray
import android.view.Gravity
import android.view.InputDevice
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.widget.FrameLayout
import androidx.core.graphics.Insets
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.pntapps.plexichore.core.EncodedInput
import com.pntapps.plexichore.core.InputEncoder
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.roundToInt

/**
 * Root view of [DisplayActivity]: a black letterbox with an aspect-fitted SurfaceView and an
 * overlay on top. Pointer events are routed per gesture: to the overlay only when the gesture
 * starts on one of its interactive regions, otherwise to the host (with local detection of the
 * 3-finger tap and the top-edge swipe that reveal the controls).
 */
@SuppressLint("ViewConstructor")
internal class StreamLayout(
    context: Context,
    private val callbacks: Callbacks,
) : FrameLayout(context) {

    interface Callbacks : SurfaceHolder.Callback {
        fun onInput(input: EncodedInput)
        fun onControlsGesture(toggle: Boolean)
        /** Window size of the display (rotation, split screen, fold/unfold). */
        fun onViewportChanged(widthPx: Int, heightPx: Int) {}
    }

    var surfaceView: SurfaceView = newSurfaceView()
        private set

    /** On-screen video rectangle in this view's coordinates. */
    val contentRect = RectF()

    /** When false (connecting / pairing) every touch goes to the overlay. */
    var forwardInput = false

    /** Overlay areas that take touches (pill buttons etc.), in this view's coordinates. */
    var interactiveRegions: List<RectF> = emptyList()

    var controlsVisible = false

    private var videoW = 16
    private var videoH = 10

    // Read live: DisplayActivity handles density changes itself (DeX, "Display size") without recreation.
    private val density get() = resources.displayMetrics.density
    private val edgePx get() = 20 * density
    private val swipePx get() = 56 * density
    private val slopPx get() = 12 * density

    /**
     * Area the video must stay inside: the display cutout (camera notch / punch hole) and any
     * *visible* system bars, caption bar (freeform / DeX / desktop windowing) or taskbar. In true
     * immersive mode the hidden bars report 0, so the picture stays full-screen there.
     */
    private var safeLeft = 0
    private var safeTop = 0
    private var safeRight = 0
    private var safeBottom = 0

    init {
        setBackgroundColor(Color.BLACK)
        isMotionEventSplittingEnabled = false
        addView(surfaceView, 0)
        ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
            val bars = insets.getInsets(
                WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.captionBar() or WindowInsetsCompat.Type.tappableElement(),
            )
            val cut = insets.getInsets(WindowInsetsCompat.Type.displayCutout())
            val safe = Insets.max(bars, cut)
            if (safe.left != safeLeft || safe.top != safeTop || safe.right != safeRight || safe.bottom != safeBottom) {
                safeLeft = safe.left; safeTop = safe.top; safeRight = safe.right; safeBottom = safe.bottom
                post { applyFit() }
            }
            insets // not consumed: the Compose overlay pads its controls with the same insets
        }
    }

    private fun newSurfaceView() = SurfaceView(context).apply {
        layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT, Gravity.CENTER)
        holder.addCallback(callbacks)
        isFocusable = false
    }

    /**
     * Replaces the SurfaceView (and therefore its Surface). Needed when switching between the
     * canvas-based MJPEG renderer and MediaCodec, which cannot share one Surface producer.
     */
    fun recreateSurface() {
        val old = surfaceView
        // Detach the decoder synchronously while the old Surface is still valid.
        callbacks.surfaceDestroyed(old.holder)
        old.holder.removeCallback(callbacks)
        removeView(old)
        surfaceView = newSurfaceView()
        addView(surfaceView, 0)
        applyFit()
    }

    fun setVideoSize(width: Int, height: Int) {
        if (width <= 0 || height <= 0 || (width == videoW && height == videoH)) return
        videoW = width
        videoH = height
        applyFit()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        callbacks.onViewportChanged(w, h)
        post { applyFit() }
    }

    private fun applyFit() {
        if (width == 0 || height == 0) return
        // Fit inside the safe area (never under a notch or a visible bar), centred in it.
        val w = (width - safeLeft - safeRight).coerceAtLeast(1)
        val h = (height - safeTop - safeBottom).coerceAtLeast(1)
        val scale = minOf(w.toFloat() / videoW, h.toFloat() / videoH)
        val fw = (videoW * scale).roundToInt().coerceIn(1, w)
        val fh = (videoH * scale).roundToInt().coerceIn(1, h)
        val left = safeLeft + (w - fw) / 2
        val top = safeTop + (h - fh) / 2
        contentRect.set(left.toFloat(), top.toFloat(), (left + fw).toFloat(), (top + fh).toFloat())
        val lp = surfaceView.layoutParams as LayoutParams
        if (lp.width != fw || lp.height != fh || lp.leftMargin != left || lp.topMargin != top || lp.gravity != (Gravity.TOP or Gravity.START)) {
            lp.width = fw
            lp.height = fh
            lp.gravity = Gravity.TOP or Gravity.START
            lp.leftMargin = left
            lp.topMargin = top
            surfaceView.layoutParams = lp
        }
    }

    // ---- Touch routing -------------------------------------------------------------------

    private enum class Mode { IDLE, OVERLAY, FORWARD, EDGE_PENDING, LOCAL }

    private var mode = Mode.IDLE
    private val edgeBuffer = ArrayList<EncodedInput>()
    private var downX = 0f
    private var downY = 0f
    private var downTime = 0L
    private var threeFingerTime = 0L
    private var threeFingerMoved = false
    private val threeFingerStart = SparseArray<PointF>()

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (ev.actionMasked == MotionEvent.ACTION_DOWN) {
            mode = when {
                !forwardInput -> Mode.OVERLAY
                controlsVisible && interactiveRegions.any { it.contains(ev.x, ev.y) } -> Mode.OVERLAY
                ev.y < edgePx && !controlsVisible -> Mode.EDGE_PENDING
                else -> Mode.FORWARD
            }
            downX = ev.x
            downY = ev.y
            downTime = ev.eventTime
            edgeBuffer.clear()
            if (mode == Mode.OVERLAY) return super.dispatchTouchEvent(ev)
            if (mode == Mode.EDGE_PENDING) {
                encode(ev)?.let { edgeBuffer.add(it) }
                return true
            }
        } else if (mode == Mode.OVERLAY) {
            val handled = super.dispatchTouchEvent(ev)
            if (ev.isEnd()) mode = Mode.IDLE
            return handled
        }

        if (mode == Mode.EDGE_PENDING) handleEdgePending(ev)
        when (mode) {
            Mode.FORWARD -> handleForward(ev)
            Mode.LOCAL -> handleLocal(ev)
            else -> Unit
        }
        if (ev.isEnd()) mode = Mode.IDLE
        return true
    }

    private fun handleEdgePending(ev: MotionEvent) {
        val dy = ev.y - downY
        val dx = abs(ev.x - downX)
        when {
            ev.actionMasked == MotionEvent.ACTION_CANCEL -> {
                edgeBuffer.clear()
                mode = Mode.IDLE
            }
            ev.actionMasked == MotionEvent.ACTION_MOVE && dy > swipePx && dx < dy -> {
                edgeBuffer.clear()
                mode = Mode.LOCAL
                threeFingerTime = 0L
                callbacks.onControlsGesture(toggle = false)
            }
            ev.actionMasked == MotionEvent.ACTION_MOVE && ev.pointerCount == 1 && dx < slopPx * 2 &&
                ev.eventTime - downTime < EDGE_DECISION_MS -> {
                // Undecided: keep buffering, coalescing moves.
                val enc = encode(ev) ?: return
                val last = edgeBuffer.lastOrNull()
                if (last != null && last.coalesceKey != 0L && last.coalesceKey == enc.coalesceKey) {
                    edgeBuffer[edgeBuffer.lastIndex] = enc
                } else edgeBuffer.add(enc)
            }
            else -> {
                // Not a swipe (tap at the top, sideways drag, timeout, second finger): replay.
                edgeBuffer.forEach(callbacks::onInput)
                edgeBuffer.clear()
                mode = Mode.FORWARD // the current event is forwarded by handleForward
            }
        }
    }

    private fun handleForward(ev: MotionEvent) {
        if (ev.actionMasked == MotionEvent.ACTION_POINTER_DOWN && fingerCount(ev) >= 3) {
            // Third finger: retract the gesture from the host and handle it locally.
            encode(ev, forceAction = InputEncoder.ACTION_CANCEL, excludeIndex = ev.actionIndex)?.let(callbacks::onInput)
            mode = Mode.LOCAL
            threeFingerTime = ev.eventTime
            threeFingerMoved = false
            threeFingerStart.clear()
            for (i in 0 until ev.pointerCount) threeFingerStart.put(ev.getPointerId(i), PointF(ev.getX(i), ev.getY(i)))
            return
        }
        encode(ev)?.let(callbacks::onInput)
    }

    private fun handleLocal(ev: MotionEvent) {
        if (threeFingerTime == 0L) return
        when (ev.actionMasked) {
            MotionEvent.ACTION_MOVE, MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_UP -> {
                for (i in 0 until ev.pointerCount) {
                    val start = threeFingerStart[ev.getPointerId(i)] ?: continue
                    if (hypot(ev.getX(i) - start.x, ev.getY(i) - start.y) > slopPx * 2) threeFingerMoved = true
                }
            }
        }
        if (ev.actionMasked == MotionEvent.ACTION_UP) {
            if (!threeFingerMoved && ev.eventTime - threeFingerTime < THREE_FINGER_TAP_MS) {
                callbacks.onControlsGesture(toggle = true)
            }
            threeFingerTime = 0L
        }
    }

    override fun dispatchGenericMotionEvent(ev: MotionEvent): Boolean {
        if (!ev.isFromSource(InputDevice.SOURCE_CLASS_POINTER)) return super.dispatchGenericMotionEvent(ev)
        if (forwardInput && mode != Mode.OVERLAY) {
            when (ev.actionMasked) {
                MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_MOVE, MotionEvent.ACTION_HOVER_EXIT,
                MotionEvent.ACTION_SCROLL -> encode(ev)?.let(callbacks::onInput)
            }
        }
        // Consume everything (incl. BUTTON_PRESS) so e.g. a mouse right-click never becomes BACK.
        return super.dispatchGenericMotionEvent(ev) || forwardInput
    }

    private fun encode(ev: MotionEvent, forceAction: Int? = null, excludeIndex: Int = -1): EncodedInput? =
        InputEncoder.encode(ev, contentRect, forceAction, excludeIndex)

    private fun fingerCount(ev: MotionEvent): Int {
        var n = 0
        for (i in 0 until ev.pointerCount) if (ev.getToolType(i) == MotionEvent.TOOL_TYPE_FINGER) n++
        return n
    }

    private fun MotionEvent.isEnd() = actionMasked == MotionEvent.ACTION_UP || actionMasked == MotionEvent.ACTION_CANCEL

    override fun onTouchEvent(event: MotionEvent): Boolean = true

    private companion object {
        const val EDGE_DECISION_MS = 350L
        const val THREE_FINGER_TAP_MS = 450L
    }
}
