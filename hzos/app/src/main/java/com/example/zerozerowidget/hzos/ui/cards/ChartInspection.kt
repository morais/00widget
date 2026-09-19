package com.example.zerozerowidget.hzos.ui.cards

import com.example.zerozerowidget.hzos.data.DashboardChart
import kotlin.math.abs

/**
 * Kotlin mirror of ChartInspection.swift: what a pointed-at chart position
 * shows. Same rows iOS shows — per-series values + total, range low/value/
 * high, reference row — and the same comparison sentences
 * ("1.2 kW above target", "Matches target", "Within range").
 */
data class InspectionValue(
    val id: String,
    val label: String?,
    val value: Double,
    val kind: Kind,
) {
    enum class Kind { VALUE, SERIES, TOTAL, RANGE_LOW, RANGE_VALUE, RANGE_HIGH, REFERENCE }
}

data class InspectionSnapshot(
    val index: Int,
    val count: Int,
    val label: String?,
    val signal: String?,
    val values: List<InspectionValue>,
    /** "X above target" / "Matches target" / "Within range" / null. */
    val comparison: String?,
)

fun formatChartValue(value: Double, unit: String?): String {
    val number = if (value == value.toLong().toDouble()) {
        value.toLong().toString()
    } else {
        "%.2f".format(value).trimEnd('0').trimEnd('.')
    }
    return if (unit.isNullOrBlank()) number else "$number $unit"
}

fun inspectChart(chart: DashboardChart, requestedIndex: Int, unit: String?): InspectionSnapshot? {
    if (chart.points.isEmpty()) return null
    val index = requestedIndex.coerceIn(0, chart.points.size - 1)
    val category = chart.categories?.getOrNull(index)
    val label = category?.label ?: chart.labels?.getOrNull(index)

    val values = mutableListOf<InspectionValue>()
    var comparisonValue: Double? = null
    var inspectedRange: com.example.zerozerowidget.hzos.data.DashboardChartRange? = null

    val ranges = chart.ranges
    if (chart.style == "range" && ranges != null && index in ranges.indices) {
        val range = ranges[index]
        inspectedRange = range
        values += InspectionValue("low", "Low", range.low, InspectionValue.Kind.RANGE_LOW)
        range.value?.let {
            values += InspectionValue(
                "range-value",
                chart.rangeValueLabel ?: "Value",
                it,
                InspectionValue.Kind.RANGE_VALUE,
            )
            comparisonValue = it
        }
        values += InspectionValue("high", "High", range.high, InspectionValue.Kind.RANGE_HIGH)
    } else {
        val series = chart.series.orEmpty()
        if (series.isNotEmpty()) {
            series.forEach { entry ->
                entry.points.getOrNull(index)?.let {
                    values += InspectionValue(
                        "series-${entry.id}",
                        entry.label,
                        it,
                        InspectionValue.Kind.SERIES,
                    )
                }
            }
            if (values.size > 1) {
                values += InspectionValue(
                    "total", "Total", chart.points[index], InspectionValue.Kind.TOTAL,
                )
            }
            comparisonValue = chart.points[index]
        } else {
            values += InspectionValue("value", "Value", chart.points[index], InspectionValue.Kind.VALUE)
            comparisonValue = chart.points[index]
        }
    }

    chart.reference?.let { ref ->
        values += InspectionValue(
            "reference",
            chart.referenceMetadata?.label ?: "Reference",
            ref,
            InspectionValue.Kind.REFERENCE,
        )
    }

    val refLabel = (chart.referenceMetadata?.label ?: "reference").lowercase()
    val comparison = when {
        comparisonValue != null && chart.reference != null -> {
            val diff = comparisonValue - chart.reference
            when {
                abs(diff) < 0.000001 -> "Matches $refLabel"
                else -> "${formatChartValue(abs(diff), unit)} ${if (diff > 0) "above" else "below"} $refLabel"
            }
        }
        comparisonValue == null && inspectedRange != null && chart.reference != null -> {
            rangeComparison(inspectedRange, chart.reference, refLabel, unit)
        }
        else -> null
    }

    return InspectionSnapshot(
        index = index,
        count = chart.points.size,
        label = label,
        signal = category?.signal,
        values = values,
        comparison = comparison,
    )
}

private fun rangeComparison(
    range: com.example.zerozerowidget.hzos.data.DashboardChartRange,
    reference: Double,
    refLabel: String,
    unit: String?,
): String {
    if (reference in range.low..range.high) return "Within range"
    val (direction, near, far) = if (range.low > reference) {
        Triple("above", range.low - reference, range.high - reference)
    } else {
        Triple("below", reference - range.high, reference - range.low)
    }
    val amount = if (abs(near - far) < 0.000001) {
        formatChartValue(near, unit)
    } else {
        "${formatChartValue(near, null)}–${formatChartValue(far, unit)}"
    }
    return "$amount $direction $refLabel"
}
