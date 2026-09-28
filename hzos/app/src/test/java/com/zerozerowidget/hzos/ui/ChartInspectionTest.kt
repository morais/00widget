package com.zerozerowidget.hzos.ui

import com.zerozerowidget.hzos.data.DashboardChart
import com.zerozerowidget.hzos.data.DashboardChartSeries
import com.zerozerowidget.hzos.ui.cards.InspectionValue
import com.zerozerowidget.hzos.ui.cards.inspectChart
import java.util.Locale
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/** What the pointed-at readout says, mirroring ChartInspection.swift. */
class ChartInspectionTest {
    // formatChartValue formats with the default locale; pin one so the
    // expected strings do not depend on the machine running the test.
    private lateinit var saved: Locale

    @Before
    fun pinLocale() {
        saved = Locale.getDefault()
        Locale.setDefault(Locale.US)
    }

    @After
    fun restoreLocale() = Locale.setDefault(saved)

    @Test
    fun comparesThePointedValueWithTheReference() {
        val chart = DashboardChart(points = listOf(10.0, 12.5, 8.0), reference = 10.0)
        assertEquals("2.5 kW above reference", inspectChart(chart, 1, "kW")!!.comparison)
        assertEquals("2 kW below reference", inspectChart(chart, 2, "kW")!!.comparison)
        assertEquals("Matches reference", inspectChart(chart, 0, "kW")!!.comparison)
    }

    @Test
    fun seriesListEachValueThenTheTotal() {
        val chart = DashboardChart(
            points = listOf(5.0, 7.0),
            style = "bar",
            series = listOf(
                DashboardChartSeries(id = "a", label = "Solar", points = listOf(3.0, 4.0)),
                DashboardChartSeries(id = "b", label = "Grid", points = listOf(2.0, 3.0))
            )
        )
        val values = inspectChart(chart, 1, null)!!.values
        assertEquals(listOf("Solar", "Grid", "Total"), values.map { it.label })
        assertEquals(listOf(4.0, 3.0, 7.0), values.map { it.value })
        assertEquals(InspectionValue.Kind.TOTAL, values.last().kind)
    }

    @Test
    fun anOutOfRangeIndexClampsAndAnEmptyChartHasNoReadout() {
        val chart = DashboardChart(points = listOf(1.0, 2.0))
        assertEquals(1, inspectChart(chart, 99, null)!!.index)
        assertNull(inspectChart(DashboardChart(points = emptyList()), 0, null))
    }
}
