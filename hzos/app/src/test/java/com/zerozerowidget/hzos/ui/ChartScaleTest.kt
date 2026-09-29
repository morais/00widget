package com.zerozerowidget.hzos.ui

import com.zerozerowidget.hzos.data.DashboardChart
import com.zerozerowidget.hzos.data.DashboardChartRange
import com.zerozerowidget.hzos.ui.cards.ChartScale
import com.zerozerowidget.hzos.ui.cards.chartScale
import org.junit.Assert.assertEquals
import org.junit.Test

/** The vertical scale a sparkline draws against, mirroring SparklineView's `plotted`. */
class ChartScaleTest {
    @Test
    fun spansThePoints() {
        assertEquals(ChartScale(2.0, 9.0, false), chartScale(DashboardChart(points = listOf(4.0, 2.0, 9.0))))
    }

    @Test
    fun anUnpinnedEdgeStretchesToKeepTheReference() {
        assertEquals(ChartScale(2.0, 12.0, true), chartScale(DashboardChart(points = listOf(2.0, 9.0), reference = 12.0)))
    }

    @Test
    fun aPinnedEdgeOmitsAReferenceOutsideIt() {
        val chart = DashboardChart(points = listOf(2.0, 9.0), max = 10.0, reference = 12.0)
        assertEquals(ChartScale(2.0, 10.0, false), chartScale(chart))
    }

    @Test
    fun rangesWidenTheScale() {
        val chart = DashboardChart(
            points = listOf(5.0, 6.0),
            style = "range",
            ranges = listOf(DashboardChartRange(low = 1.0, high = 7.0), DashboardChartRange(low = 4.0, high = 11.0))
        )
        assertEquals(ChartScale(1.0, 11.0, false), chartScale(chart))
    }
}
