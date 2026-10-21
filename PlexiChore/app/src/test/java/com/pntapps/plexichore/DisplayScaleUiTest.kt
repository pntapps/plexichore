package com.pntapps.plexichore

import com.pntapps.plexichore.ui.components.DisplayScaleUi
import org.junit.Assert.assertEquals
import org.junit.Test

class DisplayScaleUiTest {
    @Test fun autoMatchesHost() {
        assertEquals(150, DisplayScaleUi.autoPercent(240))
        assertEquals(200, DisplayScaleUi.autoPercent(320))
        assertEquals(200, DisplayScaleUi.autoPercent(340))
        assertEquals(250, DisplayScaleUi.autoPercent(480))
        assertEquals(125, DisplayScaleUi.autoPercent(160))
        assertEquals(100, DisplayScaleUi.autoPercent(320, 0.5f))
    }

    @Test fun cycleAndLabels() {
        assertEquals(150, DisplayScaleUi.next(0))
        assertEquals(0, DisplayScaleUi.next(250))
        assertEquals(0, DisplayScaleUi.next(125)) // a value not offered here goes back to Auto
        assertEquals("Auto", DisplayScaleUi.label(0))
        assertEquals("175%", DisplayScaleUi.label(175))
        assertEquals("2×", DisplayScaleUi.factor(200))
        assertEquals("1.5×", DisplayScaleUi.factor(150))
        assertEquals("1.75×", DisplayScaleUi.factor(175))
        assertEquals("Text and pointer at 2×", DisplayScaleUi.preview(200, 320, 1f))
    }

    @Test fun largerAndSmaller() {
        // Auto counts as what the host applied (200% on a Tab S8)
        assertEquals(225, DisplayScaleUi.larger(0, 200))
        assertEquals(175, DisplayScaleUi.smaller(0, 200))
        // before CONFIG: Auto assumed 200
        assertEquals(225, DisplayScaleUi.larger(0, 0))
        assertEquals(250, DisplayScaleUi.larger(225, 200))
        assertEquals(null, DisplayScaleUi.larger(250, 200))
        assertEquals(null, DisplayScaleUi.smaller(150, 200))
        // an applied value between steps moves to the neighbouring step
        assertEquals(150, DisplayScaleUi.larger(0, 125))
        assertEquals(null, DisplayScaleUi.smaller(0, 125))
    }
}
