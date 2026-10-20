package com.pntapps.plexichore.core

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import com.pntapps.plexichore.R
import com.pntapps.plexichore.display.DisplayActivity

/**
 * Foreground service that keeps the process (and a low-latency Wi-Fi lock) alive while a
 * session is active. The session itself lives in [PlexiCoreConnection]; this service only
 * provides process priority, the ongoing notification and its Disconnect action.
 */
class StreamService : Service() {

    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_DISCONNECT) {
            PlexiCore.impl(this).disconnect()
            return START_NOT_STICKY
        }
        val hostName = intent?.getStringExtra(EXTRA_HOST) ?: getString(R.string.app_name)
        try {
            val notification = buildNotification(this, hostName)
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.w(TAG, "startForeground failed", e)
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        acquireWifiLock()
        // Never restarted by the system: a dead process has no session to resume.
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // App swiped away from recents: end the session cleanly.
        PlexiCore.impl(this).disconnect()
        stopSelf()
    }

    override fun onDestroy() {
        running = false
        wifiLock?.let { if (it.isHeld) runCatching { it.release() } }
        wifiLock = null
        super.onDestroy()
    }

    private fun acquireWifiLock() {
        if (wifiLock?.isHeld == true) return
        val wifi = applicationContext.getSystemService(WifiManager::class.java) ?: return
        @Suppress("DEPRECATION")
        val mode = if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
        wifiLock = runCatching {
            wifi.createWifiLock(mode, "plexichore-stream").apply {
                setReferenceCounted(false)
                acquire()
            }
        }.getOrNull()
    }

    companion object {
        private const val TAG = "PlexiService"
        private const val CHANNEL_ID = "plexi_session"
        private const val NOTIFICATION_ID = 4780
        private const val EXTRA_HOST = "host"
        private const val ACTION_DISCONNECT = "com.pntapps.plexichore.action.DISCONNECT"

        @Volatile private var running = false

        internal fun start(context: Context, hostName: String) {
            val intent = Intent(context, StreamService::class.java).putExtra(EXTRA_HOST, hostName)
            try {
                context.startForegroundService(intent)
            } catch (e: Exception) {
                // e.g. ForegroundServiceStartNotAllowedException when started from background.
                Log.w(TAG, "Cannot start foreground service", e)
            }
        }

        /** Refreshes the ongoing notification (e.g. once the host's real name is known). */
        internal fun update(context: Context, hostName: String) {
            if (!running) return
            runCatching {
                context.getSystemService(NotificationManager::class.java)
                    .notify(NOTIFICATION_ID, buildNotification(context, hostName))
            }
        }

        internal fun stop(context: Context) {
            context.stopService(Intent(context, StreamService::class.java))
        }

        private fun buildNotification(context: Context, hostName: String): Notification {
            val nm = context.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Display session", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "Shown while this tablet is used as a display"
                        setShowBadge(false)
                    }
                )
            }
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, DisplayActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val stop = PendingIntent.getService(
                context, 1,
                Intent(context, StreamService::class.java).setAction(ACTION_DISCONNECT),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            return Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_plexichore)
                .setContentTitle("Connected to $hostName")
                .setContentText("This tablet is being used as a display")
                .setContentIntent(open)
                .setOngoing(true)
                .setCategory(Notification.CATEGORY_SERVICE)
                .addAction(Notification.Action.Builder(null, "Disconnect", stop).build())
                .apply { if (Build.VERSION.SDK_INT >= 31) setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE) }
                .build()
        }
    }
}
