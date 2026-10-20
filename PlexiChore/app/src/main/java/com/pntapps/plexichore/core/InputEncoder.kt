package com.pntapps.plexichore.core

import android.graphics.RectF
import android.view.MotionEvent
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.tan

/** An encoded INPUT frame plus the key under which consecutive moves may be coalesced. */
internal class EncodedInput(val frame: ByteArray, val coalesceKey: Long)

/**
 * Converts Android MotionEvents into protocol INPUT frames. Coordinates are normalized to
 * [content], the on-screen rectangle of the video (letterbox excluded), in the same coordinate
 * space as the event.
 */
internal object InputEncoder {
    const val KIND_TOUCH = 0
    const val KIND_PEN = 1
    const val KIND_MOUSE = 2
    const val KIND_SCROLL = 3

    const val ACTION_DOWN = 0
    const val ACTION_MOVE = 1
    const val ACTION_UP = 2
    const val ACTION_CANCEL = 3
    const val ACTION_HOVER_MOVE = 4
    const val ACTION_HOVER_EXIT = 5

    private const val BTN_PRIMARY = 0x01
    private const val BTN_SECONDARY = 0x02
    private const val BTN_ERASER = 0x04

    private const val MAX_POINTERS = 10
    private const val POINTER_BYTES = 24
    private const val MAX_TILT_RAD = 1.5f // ~86°, keeps tan() finite

    /**
     * Encodes [ev]. [excludeIndex] omits one pointer, [forceAction] overrides every pointer's
     * action (used to synthesize CANCEL). Returns null for events that carry nothing useful.
     */
    fun encode(
        ev: MotionEvent,
        content: RectF,
        forceAction: Int? = null,
        excludeIndex: Int = -1,
    ): EncodedInput? {
        val masked = ev.actionMasked
        if (masked == MotionEvent.ACTION_SCROLL) return encodeScroll(ev)
        val count = minOf(ev.pointerCount - if (excludeIndex >= 0) 1 else 0, MAX_POINTERS)
        if (count <= 0) return null
        val actionIndex = ev.actionIndex
        val buf = frameBuffer(count)
        var allMoves = true
        var idMask = 0L
        var written = 0
        for (i in 0 until ev.pointerCount) {
            if (i == excludeIndex) continue
            if (written == count) break
            val tool = ev.getToolType(i)
            val kind = when (tool) {
                MotionEvent.TOOL_TYPE_STYLUS, MotionEvent.TOOL_TYPE_ERASER -> KIND_PEN
                MotionEvent.TOOL_TYPE_MOUSE -> KIND_MOUSE
                else -> KIND_TOUCH
            }
            val action = forceAction ?: pointerAction(masked, i, actionIndex) ?: return null
            if (action != ACTION_MOVE && action != ACTION_HOVER_MOVE) allMoves = false
            val contact = action == ACTION_DOWN || action == ACTION_MOVE
            val state = ev.buttonState
            var buttons = 0
            when (kind) {
                KIND_MOUSE -> {
                    if (state and MotionEvent.BUTTON_PRIMARY != 0) buttons = buttons or BTN_PRIMARY
                    if (state and MotionEvent.BUTTON_SECONDARY != 0) buttons = buttons or BTN_SECONDARY
                }
                KIND_PEN -> {
                    if (contact) buttons = buttons or BTN_PRIMARY
                    if (state and (MotionEvent.BUTTON_STYLUS_PRIMARY or MotionEvent.BUTTON_SECONDARY) != 0) {
                        buttons = buttons or BTN_SECONDARY
                    }
                    if (tool == MotionEvent.TOOL_TYPE_ERASER) buttons = buttons or BTN_ERASER
                }
                else -> if (contact) buttons = BTN_PRIMARY
            }
            val id = ev.getPointerId(i) and 0xFF
            idMask = idMask or (1L shl (id and 31))
            val x = norm(ev.getX(i), content.left, content.width())
            val y = norm(ev.getY(i), content.top, content.height())
            val pressure = if (contact) ev.getPressure(i).coerceIn(0f, 1f) else 0f
            var tiltX = 0f
            var tiltY = 0f
            if (kind == KIND_PEN) {
                val tilt = ev.getAxisValue(MotionEvent.AXIS_TILT, i).coerceIn(0f, MAX_TILT_RAD)
                val orientation = ev.getAxisValue(MotionEvent.AXIS_ORIENTATION, i)
                // Android: tilt from vertical + azimuth (0 = toward the top, clockwise).
                // Protocol: per-axis tilt in degrees, +X right, +Y toward the user (down).
                val t = tan(tilt)
                tiltX = Math.toDegrees(atan(t * sin(orientation)).toDouble()).toFloat()
                tiltY = Math.toDegrees(atan(-t * cos(orientation)).toDouble()).toFloat()
            }
            buf.put(kind.toByte()).put(action.toByte()).put(id.toByte()).put(buttons.toByte())
                .putFloat(x).putFloat(y).putFloat(pressure).putFloat(tiltX).putFloat(tiltY)
            written++
        }
        val key = if (allMoves && forceAction == null) (idMask shl 8) or (masked.toLong() and 0xFF) or (1L shl 62) else OutboundQueue.NO_COALESCE
        return EncodedInput(buf.array(), key)
    }

    private fun encodeScroll(ev: MotionEvent): EncodedInput? {
        val dx = ev.getAxisValue(MotionEvent.AXIS_HSCROLL)
        val dy = ev.getAxisValue(MotionEvent.AXIS_VSCROLL)
        if (dx == 0f && dy == 0f) return null
        val buf = frameBuffer(1)
        buf.put(KIND_SCROLL.toByte()).put(ACTION_MOVE.toByte()).put(0).put(0)
            .putFloat(dx).putFloat(dy).putFloat(0f).putFloat(0f).putFloat(0f)
        return EncodedInput(buf.array(), OutboundQueue.NO_COALESCE)
    }

    private fun frameBuffer(count: Int): ByteBuffer {
        val payload = 1 + count * POINTER_BYTES
        val buf = ByteBuffer.allocate(Protocol.HEADER_SIZE + payload).order(ByteOrder.BIG_ENDIAN)
        buf.put(Protocol.INPUT.toByte()).putInt(payload).put(count.toByte())
        return buf
    }

    private fun pointerAction(masked: Int, i: Int, actionIndex: Int): Int? = when (masked) {
        MotionEvent.ACTION_DOWN -> ACTION_DOWN
        MotionEvent.ACTION_POINTER_DOWN -> if (i == actionIndex) ACTION_DOWN else ACTION_MOVE
        MotionEvent.ACTION_MOVE -> ACTION_MOVE
        MotionEvent.ACTION_UP -> ACTION_UP
        MotionEvent.ACTION_POINTER_UP -> if (i == actionIndex) ACTION_UP else ACTION_MOVE
        MotionEvent.ACTION_CANCEL -> ACTION_CANCEL
        MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_MOVE -> ACTION_HOVER_MOVE
        MotionEvent.ACTION_HOVER_EXIT -> ACTION_HOVER_EXIT
        // BUTTON_PRESS/RELEASE are redundant: the following move/hover carries buttonState.
        else -> null
    }

    private fun norm(v: Float, origin: Float, size: Float): Float =
        if (size <= 0f) 0f else ((v - origin) / size).coerceIn(0f, 1f)
}
