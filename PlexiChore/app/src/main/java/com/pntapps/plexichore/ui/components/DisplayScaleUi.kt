package com.pntapps.plexichore.ui.components

import java.util.Locale
import kotlin.math.abs

/**
 * "Display size": the host's display scale (Windows DPI) for the tablet's virtual monitor (extend / primary).
 * 0 = Auto. Mirrors the host's DisplayScale.Auto so the UI can preview what Auto will pick.
 */
object DisplayScaleUi {
    /** Choices offered in Settings and the in-stream pill (0 = Auto). */
    val options: List<Int> = listOf(0, 150, 175, 200, 225, 250)

    private val steps = listOf(100, 125, 150, 175, 200, 225, 250, 300)

    fun label(percent: Int): String = if (percent <= 0) "Auto" else "$percent%"

    /** Next value for the overlay "Size" button (cycles through [options]). */
    fun next(percent: Int): Int {
        val i = options.indexOf(percent)
        return options[(if (i < 0) 0 else i + 1) % options.size]
    }

    /**
     * What Auto resolves to on the host: Windows UI the same physical size as this tablet's Android UI
     * (densityDpi / 160), divided by the downscale factor, nearest step (ties → lower), clamped to 125..250
     * (100 allowed when downscaled).
     */
    fun autoPercent(densityDpi: Int, resolutionScale: Float = 1f): Int {
        val ratio = if (resolutionScale in 0.1f..1f) 1f / resolutionScale else 1f
        val pct = (if (densityDpi > 0) densityDpi / 160.0 else 2.0) * 100.0 / ratio
        var best = steps[0]
        var bestDiff = Double.MAX_VALUE
        for (s in steps) {
            val d = abs(s - pct)
            if (d < bestDiff - 1e-9) { best = s; bestDiff = d }
        }
        val min = if (ratio > 1.15f) 100 else 125
        return best.coerceIn(min, 250)
    }

    fun factor(percent: Int): String {
        val f = percent / 100.0
        return if (percent % 100 == 0) "${percent / 100}×" else String.format(Locale.US, "%.2f×", f).replace("0×", "×")
    }

    /** "Text and pointer at 2×" / "Auto — text and pointer at 2× (matches this tablet)". */
    fun preview(percent: Int, densityDpi: Int, resolutionScale: Float): String =
        if (percent <= 0) "Auto — text and pointer at ${factor(autoPercent(densityDpi, resolutionScale))}, like this tablet's own apps"
        else "Text and pointer at ${factor(percent)}"
}
