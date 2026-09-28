package com.zerozerowidget.hzos.ui

import androidx.compose.ui.graphics.Color
import com.zerozerowidget.hzos.data.DashboardStatus
import com.zerozerowidget.hzos.ui.cards.activityTint
import com.zerozerowidget.hzos.ui.cards.chartPalette
import com.zerozerowidget.hzos.ui.cards.statusColor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * The chart palette resolves per theme mode: status and signal colors
 * come from the dark set in dark mode and the iOS light-mode mirror
 * otherwise. Unknown statuses still fall through to the caller's color.
 */
class ChartPaletteTest {

    @Test
    fun `dark and light palettes differ on every status color`() {
        val dark = chartPalette(true)
        val light = chartPalette(false)
        assertNotEquals(dark.BLUE, light.BLUE)
        assertNotEquals(dark.GREEN, light.GREEN)
        assertNotEquals(dark.ORANGE, light.ORANGE)
        assertNotEquals(dark.RED, light.RED)
        assertNotEquals(dark.SECONDARY, light.SECONDARY)
    }

    @Test
    fun `status colors follow the mode flag`() {
        val unknown = Color(0xFF000001)
        assertEquals(
            statusColor(DashboardStatus.CRITICAL, unknown, true),
            statusColor(DashboardStatus.CRITICAL, unknown, true),
        )
        assertNotEquals(
            statusColor(DashboardStatus.CRITICAL, unknown, true),
            statusColor(DashboardStatus.CRITICAL, unknown, false),
        )
        assertEquals(unknown, statusColor(DashboardStatus.UNKNOWN, unknown, true))
        assertEquals(unknown, statusColor(DashboardStatus.UNKNOWN, unknown, false))
    }

    @Test
    fun `activity tints follow the mode flag but keep the fallback`() {
        val accent = Color(0xFF000002)
        assertNotEquals(
            activityTint("charging", null, accent, true),
            activityTint("charging", null, accent, false),
        )
        assertEquals(accent, activityTint("other", null, accent, true))
        assertEquals(accent, activityTint("other", null, accent, false))
    }
}
