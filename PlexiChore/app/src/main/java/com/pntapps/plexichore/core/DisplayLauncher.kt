package com.pntapps.plexichore.core

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.util.Log
import com.pntapps.plexichore.display.DisplayActivity
import java.lang.ref.WeakReference

/**
 * Brings [DisplayActivity] up once the host sends CONFIG, robustly.
 *
 * Why this exists: the old code called `applicationContext.startActivity(NEW_TASK | SINGLE_TOP)`.
 * With NEW_TASK the system first looks for an existing task with our affinity and, in
 * `ActivityStarter.complyActivityFlags`, if that task's *root identity* (`Task.realActivity`, which
 * by default never changes after the task is created — `mNeverRelinquishIdentity`) is
 * DisplayActivity and the intent filter-equals the task's root intent, it treats the start as
 * "bring the task to front" and adds nothing. The call then returns START_DELIVERED_TO_TOP (3)
 * while MainActivity stays on top. A task gets DisplayActivity as its root identity whenever the
 * display was started without MainActivity below it (debug `DebugDisplay` alias, notification tap
 * or a launch with no task) and `DisplayActivity.close()` later put MainActivity on top of it
 * in the same task; bringing the app back via the launcher then resumes MainActivity in that task.
 *
 * Fix: launch from the resumed Activity when there is one (the start goes into the caller's task,
 * no task-reuse logic), always add FLAG_ACTIVITY_REORDER_TO_FRONT (it takes the branch that either
 * moves a live instance to front or adds a new one, never the "drop" branch), and verify within
 * [VERIFY_MS] that the activity was created, retrying a couple of times otherwise.
 */
internal class DisplayLauncher(
    private val app: Context,
    private val main: Handler,
    /** True while the display should be on screen (state is Streaming). */
    private val wanted: () -> Boolean,
) {
    private var foreground: WeakReference<Activity>? = null
    @Volatile private var displayCreated = false
    private var attempt = 0
    private var token = 0

    init {
        (app as? Application)?.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(a: Activity, b: Bundle?) {
                if (a is DisplayActivity) displayCreated = true
            }
            override fun onActivityResumed(a: Activity) { foreground = WeakReference(a) }
            override fun onActivityPaused(a: Activity) {
                if (foreground?.get() === a) foreground = null
            }
            override fun onActivityStarted(a: Activity) {}
            override fun onActivityStopped(a: Activity) {}
            override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
            override fun onActivityDestroyed(a: Activity) {
                if (a is DisplayActivity) displayCreated = false
                if (foreground?.get() === a) foreground = null
            }
        })
    }

    /** Test/diagnostic hook: the activity a launch would currently use as its context. */
    internal fun foregroundActivity(): Activity? = foreground?.get()?.takeUnless { it.isFinishing || it.isDestroyed }

    private fun isUp() = DisplayActivity.alive || displayCreated

    /** Must be called on the main thread. */
    fun request() {
        token++
        attempt = 0
        launch(token)
    }

    /** Stops pending retries (disconnect / new connection). */
    fun cancel() {
        token++
    }

    private fun launch(t: Int) {
        if (t != token || !wanted() || isUp()) return
        val from = foregroundActivity()
        val ctx: Context = from ?: app
        val flags = launchFlags(fromActivity = from != null)
        try {
            ctx.startActivity(Intent(ctx, DisplayActivity::class.java).addFlags(flags))
            Log.i(TAG, "Display launch #${attempt + 1} from ${from?.javaClass?.simpleName ?: "application"}")
        } catch (e: Exception) {
            Log.w(TAG, "Cannot launch display", e)
        }
        if (attempt < MAX_RETRIES) {
            attempt++
            main.postDelayed({
                if (t == token && wanted() && !isUp()) {
                    Log.w(TAG, "Display did not come up within $VERIFY_MS ms; retrying")
                    launch(t)
                }
            }, VERIFY_MS)
        }
    }

    companion object {
        private const val TAG = "PlexiCore"
        const val VERIFY_MS = 1_000L
        const val MAX_RETRIES = 2

        /**
         * From an Activity: no NEW_TASK, so the display goes on top of the caller's task.
         * From the application context NEW_TASK is mandatory; REORDER_TO_FRONT keeps the start
         * from being dropped when the reused task's root identity is DisplayActivity.
         */
        fun launchFlags(fromActivity: Boolean): Int {
            val base = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            return if (fromActivity) base else base or Intent.FLAG_ACTIVITY_NEW_TASK
        }
    }
}
