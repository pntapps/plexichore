package com.pntapps.plexichore.ui

import android.content.Context
import com.pntapps.plexichore.core.PlexiConnection
import com.pntapps.plexichore.core.PlexiCore
import com.pntapps.plexichore.ui.preview.FakePlexiConnection

/**
 * Single place where the UI obtains its [PlexiConnection].
 * Demo mode (Settings > About in debug builds, or `--ez demo true` launch extra) uses the fake.
 */
object ConnectionProvider {
    private val fake by lazy { FakePlexiConnection() }

    fun real(context: Context): PlexiConnection = PlexiCore.get(context.applicationContext)

    fun demo(): PlexiConnection = fake
}
