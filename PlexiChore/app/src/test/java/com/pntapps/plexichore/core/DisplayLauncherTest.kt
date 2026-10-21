package com.pntapps.plexichore.core

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.pntapps.plexichore.display.DisplayActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class DisplayLauncherTest {
    private val app: Application get() = RuntimeEnvironment.getApplication()
    private val main = Handler(Looper.getMainLooper())

    private fun Int.has(flag: Int) = this and flag == flag

    @Test
    fun flagsNeverRelyOnNewTaskSingleTopAlone() {
        val fromApp = DisplayLauncher.launchFlags(fromActivity = false)
        val fromActivity = DisplayLauncher.launchFlags(fromActivity = true)
        // NEW_TASK|SINGLE_TOP alone is dropped (START_DELIVERED_TO_TOP) when the reused task's root
        // identity is DisplayActivity; REORDER_TO_FRONT always moves or adds the activity.
        assertTrue(fromApp.has(Intent.FLAG_ACTIVITY_NEW_TASK))
        assertTrue(fromApp.has(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
        assertTrue(fromActivity.has(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
        assertTrue(fromActivity.has(Intent.FLAG_ACTIVITY_SINGLE_TOP))
        // From an Activity the display must go into the caller's task (no task-reuse lookup).
        assertEquals(0, fromActivity and Intent.FLAG_ACTIVITY_NEW_TASK)
        // Must never clear the Home screen below it.
        assertEquals(0, fromApp and (Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_CLEAR_TASK))
    }

    @Test
    fun launchesFromTheResumedActivityWhenThereIsOne() {
        val launcher = DisplayLauncher(app, main) { true }
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        assertEquals(activity, launcher.foregroundActivity())

        launcher.request()

        val started = shadowOf(activity).nextStartedActivity
        assertNotNull(started)
        assertEquals(DisplayActivity::class.java.name, started.component?.className)
        assertEquals(0, started.flags and Intent.FLAG_ACTIVITY_NEW_TASK)
        assertTrue(started.flags.has(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
    }

    @Test
    fun fallsBackToApplicationContextAndRetriesWhenTheDisplayDoesNotComeUp() {
        val launcher = DisplayLauncher(app, main) { true }
        val shadowApp = shadowOf(app)
        shadowApp.clearNextStartedActivities()

        launcher.request()
        val first = shadowApp.nextStartedActivity
        assertNotNull(first)
        assertTrue(first.flags.has(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))

        // Nothing created DisplayActivity: each verification window triggers one retry, then it stops.
        repeat(DisplayLauncher.MAX_RETRIES) {
            shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(DisplayLauncher.VERIFY_MS + 10))
            assertNotNull("retry ${it + 1}", shadowApp.nextStartedActivity)
        }
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(DisplayLauncher.VERIFY_MS * 3))
        assertNull(shadowApp.nextStartedActivity)
    }

    @Test
    fun doesNothingWhenNotStreamingAndCancelStopsRetries() {
        var wanted = false
        val launcher = DisplayLauncher(app, main) { wanted }
        val shadowApp = shadowOf(app)
        shadowApp.clearNextStartedActivities()

        launcher.request()
        assertNull(shadowApp.nextStartedActivity)

        wanted = true
        launcher.request()
        assertNotNull(shadowApp.nextStartedActivity)
        launcher.cancel()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(DisplayLauncher.VERIFY_MS * 3))
        assertNull(shadowApp.nextStartedActivity)
    }
}
