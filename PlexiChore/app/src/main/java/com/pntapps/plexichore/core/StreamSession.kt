package com.pntapps.plexichore.core

import android.os.Process
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicLong

/**
 * Outbound message queue drained by a dedicated writer thread. Messages with the same
 * non-zero coalesce key replace each other while still queued (pointer moves), so a slow link
 * never builds up a backlog of stale input.
 */
internal class OutboundQueue {
    private class Entry(var bytes: ByteArray, val key: Long)

    private val lock = Object()
    private val queue = ArrayDeque<Entry>()
    private var closed = false

    fun offer(bytes: ByteArray, coalesceKey: Long = NO_COALESCE) {
        synchronized(lock) {
            if (closed) return
            val last = queue.lastOrNull()
            if (coalesceKey != NO_COALESCE && last != null && last.key == coalesceKey) {
                last.bytes = bytes
            } else {
                if (queue.size >= MAX_QUEUED) queue.removeFirst()
                queue.addLast(Entry(bytes, coalesceKey))
            }
            lock.notifyAll()
        }
    }

    /** Blocks until something is queued; returns null once closed and drained. */
    fun takeAll(out: MutableList<ByteArray>): Boolean {
        synchronized(lock) {
            while (queue.isEmpty() && !closed) lock.wait()
            if (queue.isEmpty()) return false
            while (queue.isNotEmpty()) out.add(queue.removeFirst().bytes)
            return true
        }
    }

    fun close() {
        synchronized(lock) {
            closed = true
            lock.notifyAll()
        }
    }

    companion object {
        const val NO_COALESCE = 0L
        private const val MAX_QUEUED = 512
    }
}

/** How a session ended. */
internal sealed interface SessionEnd {
    data class HostBye(val reason: String) : SessionEnd
    data object Rejected : SessionEnd
    data class Error(val error: Throwable, val connected: Boolean) : SessionEnd
    data object Closed : SessionEnd
}

/** A single TCP connection to a host: HELLO, read loop, ping, writer. Blocking; run on IO. */
internal class StreamSession(
    val host: DiscoveredHost,
    private val hello: JSONObject,
    private val pipeline: VideoPipeline,
    private val events: Events,
) {
    interface Events {
        fun onPairing(status: String, code: String)
        fun onConfig(config: StreamConfig)
    }

    private val socket = Socket()
    private val outbound = OutboundQueue()
    @Volatile private var closedLocally = false
    @Volatile var awaitingApproval = false
        private set
    @Volatile var gotConfig = false
        private set

    val videoBytes = AtomicLong()
    /** Longest gap between two VIDEO messages (network/host smoothness), reset by [takeMaxArrivalGapNanos]. */
    @Volatile private var maxArrivalGapNanos = 0L
    private var lastVideoNanos = System.nanoTime()
    fun takeMaxArrivalGapNanos(): Long = maxArrivalGapNanos.also { maxArrivalGapNanos = 0L }
    @Volatile var rttMs = 0f
        private set
    private var lastKeyframeRequest = 0L

    fun send(bytes: ByteArray, coalesceKey: Long = OutboundQueue.NO_COALESCE) = outbound.offer(bytes, coalesceKey)

    fun sendPing() = send(Protocol.pingFrame(SystemClock.elapsedRealtimeNanos() / 1000))

    fun requestKeyframe() {
        val now = SystemClock.elapsedRealtime()
        synchronized(this) {
            if (now - lastKeyframeRequest < KEYFRAME_REQUEST_INTERVAL_MS) return
            lastKeyframeRequest = now
        }
        send(Protocol.frame(Protocol.REQUEST_KEYFRAME))
    }

    /** Sends BYE (best effort, bounded) and tears the socket down; unblocks [run]. */
    fun close(reason: String?) {
        if (closedLocally) return
        closedLocally = true
        if (reason != null && socket.isConnected) {
            // Write BYE directly so it is not stuck behind queued input.
            runCatching {
                socket.soTimeout = 300
                synchronized(writeLock) { rawOut?.apply { write(Protocol.byeFrame(reason)); flush() } }
            }
        }
        outbound.close()
        runCatching { socket.close() }
    }

    private val writeLock = Any()
    @Volatile private var rawOut: OutputStream? = null

    /** Connects and runs until the connection ends. Never throws (except on thread interrupt). */
    fun run(): SessionEnd {
        var connected = false
        try {
            socket.tcpNoDelay = true
            socket.trafficClass = 0xB8 // DSCP EF (low delay)
            socket.receiveBufferSize = 2 shl 20
            LanNetwork.bindIfVpn(socket, host.address)
            socket.connect(InetSocketAddress(host.address, host.port), CONNECT_TIMEOUT_MS)
            connected = true
            socket.soTimeout = READ_TIMEOUT_MS
            rawOut = BufferedOutputStream(socket.getOutputStream(), 64 * 1024)
            startWriter()
            send(Protocol.frame(Protocol.HELLO, hello))
            return readLoop(DataInputStream(BufferedInputStream(socket.getInputStream(), 256 * 1024)))
        } catch (e: Exception) {
            return if (closedLocally) SessionEnd.Closed else SessionEnd.Error(e, connected)
        } finally {
            outbound.close()
            runCatching { socket.close() }
        }
    }

    private fun startWriter() {
        val t = Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_DISPLAY)
            val batch = ArrayList<ByteArray>(16)
            try {
                while (outbound.takeAll(batch)) {
                    synchronized(writeLock) {
                        val out = rawOut ?: return@Thread
                        for (b in batch) out.write(b)
                        out.flush()
                    }
                    batch.clear()
                }
            } catch (e: IOException) {
                if (!closedLocally) Log.d(TAG, "Writer stopped: ${e.message}")
                runCatching { socket.close() } // make the reader notice
            } catch (_: InterruptedException) {
            }
        }, "plexi-writer")
        t.isDaemon = true
        t.start()
    }

    private fun readLoop(input: DataInputStream): SessionEnd {
        val header = ByteArray(Protocol.HEADER_SIZE)
        var approvalWaitStart = 0L
        while (true) {
            // Read the first header byte alone so a timeout never desynchronises the stream.
            val first = try {
                input.read()
            } catch (e: SocketTimeoutException) {
                // While the user approves on the host, tolerate silence (hosts may not ping then).
                if (awaitingApproval) {
                    if (approvalWaitStart == 0L) approvalWaitStart = SystemClock.elapsedRealtime()
                    if (SystemClock.elapsedRealtime() - approvalWaitStart < APPROVAL_TIMEOUT_MS) continue
                }
                throw IOException("Host stopped responding", e)
            }
            if (first < 0) throw EOFException("Host closed the connection")
            header[0] = first.toByte()
            input.readFully(header, 1, Protocol.HEADER_SIZE - 1)
            val type = first and 0xFF
            val len = ((header[1].toInt() and 0xFF) shl 24) or ((header[2].toInt() and 0xFF) shl 16) or
                ((header[3].toInt() and 0xFF) shl 8) or (header[4].toInt() and 0xFF)
            if (len < 0 || len > Protocol.MAX_PAYLOAD) throw IOException("Bad frame length $len (type $type)")
            approvalWaitStart = 0L

            when (type) {
                Protocol.VIDEO -> {
                    if (len < 9) {
                        Protocol.skipFully(input, len); continue
                    }
                    val buf = ByteArray(len)
                    input.readFully(buf)
                    videoBytes.addAndGet(len.toLong())
                    val now = System.nanoTime()
                    val gap = now - lastVideoNanos
                    lastVideoNanos = now
                    if (gap > maxArrivalGapNanos) maxArrivalGapNanos = gap
                    pipeline.submit(VideoFrame(Protocol.readLong(buf, 0), buf[8].toInt() and 0xFF, buf, 9, len - 9))
                }
                Protocol.PING -> {
                    val payload = ByteArray(len)
                    input.readFully(payload)
                    send(Protocol.frame(Protocol.PONG, payload))
                }
                Protocol.PONG -> {
                    val payload = ByteArray(len)
                    input.readFully(payload)
                    if (len >= 8) {
                        val sent = Protocol.readLong(payload, 0)
                        val rtt = (SystemClock.elapsedRealtimeNanos() / 1000 - sent) / 1000f
                        if (rtt in 0f..60_000f) rttMs = if (rttMs == 0f) rtt else rttMs * 0.7f + rtt * 0.3f
                    }
                }
                Protocol.CONFIG -> {
                    val json = readJson(input, len)
                    val config = Protocol.parseConfig(json, host)
                    awaitingApproval = false
                    gotConfig = true
                    pipeline.setConfig(config)
                    events.onConfig(config)
                }
                Protocol.PAIRING -> {
                    val json = readJson(input, len)
                    val status = json.optString("status")
                    when (status) {
                        "waiting" -> awaitingApproval = true
                        "approved" -> awaitingApproval = false
                        "rejected" -> return SessionEnd.Rejected
                    }
                    events.onPairing(status, json.optString("code"))
                }
                Protocol.BYE -> {
                    val payload = ByteArray(len)
                    input.readFully(payload)
                    return SessionEnd.HostBye(String(payload, Charsets.UTF_8))
                }
                else -> Protocol.skipFully(input, len) // STATS and unknown types
            }
        }
    }

    private fun readJson(input: DataInputStream, len: Int): JSONObject {
        val payload = ByteArray(len)
        input.readFully(payload)
        return runCatching { JSONObject(String(payload, Charsets.UTF_8)) }.getOrElse { JSONObject() }
    }

    companion object {
        private const val TAG = "PlexiSession"
        const val CONNECT_TIMEOUT_MS = 5_000
        const val READ_TIMEOUT_MS = 5_000
        private const val APPROVAL_TIMEOUT_MS = 120_000L
        private const val KEYFRAME_REQUEST_INTERVAL_MS = 300L
    }
}
