package com.example.zerozerowidget.hzos.ui.cards

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import com.example.zerozerowidget.hzos.data.DashboardChart

/**
 * Chart plot + pointed-at readout, mirroring InspectableChartView: the plot
 * draws a selection rule at the inspected index (plus a wash band for
 * categorical styles), and a panel below lists the label, per-series or
 * range values, the reference row, and the comparison sentence.
 *
 * Pointing works with hover (ray/mouse Move, no press) and touch (press or
 * drag). Events are never consumed, so a vertical drag still scrolls the
 * surrounding list while the readout follows the pointer — the pragmatic
 * counterpart to iOS's gesture arbitration.
 */
@Composable
fun InspectableChart(
    chart: DashboardChart,
    unit: String?,
    baseTint: Color,
    modifier: Modifier = Modifier,
) {
    var selectedIndex by remember(chart) {
        mutableIntStateOf(maxOf(0, chart.points.size - 1))
    }
    val count = chart.points.size
    if (count == 0) return
    val snapshot = remember(chart, selectedIndex, unit) {
        inspectChart(chart, selectedIndex, unit)
    }

    Column(modifier) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(140.dp)
                .pointerInput(chart) {
                    awaitPointerEventScope {
                        while (true) {
                            val event = awaitPointerEvent()
                            val x = event.changes.firstOrNull()?.position?.x ?: continue
                            when (event.type) {
                                PointerEventType.Move,
                                PointerEventType.Press,
                                -> {
                                    val width = size.width.toFloat()
                                    if (width > 0) {
                                        selectedIndex = indexAt(
                                            chart,
                                            (x / width).coerceIn(0f, 1f),
                                        )
                                    }
                                }
                                PointerEventType.Release,
                                PointerEventType.Exit,
                                -> Unit // selection sticks, like iOS
                                else -> Unit
                            }
                        }
                    }
                },
        ) {
            Sparkline(chart = chart, baseTint = baseTint, modifier = Modifier.matchParentSize())
            SelectionOverlay(chart = chart, index = selectedIndex, tint = baseTint)
        }
        snapshot?.let { InspectionPanel(snapshot = it, unit = unit) }
    }
}

/** Slot for categorical styles, proportional position for lines (mirrors iOS). */
private fun indexAt(chart: DashboardChart, fraction: Float): Int {
    val count = chart.points.size
    if (count <= 1) return 0
    return if (chart.style == "line") {
        (fraction * (count - 1)).toInt().coerceIn(0, count - 1)
    } else {
        (fraction * count).toInt().coerceIn(0, count - 1)
    }
}

@Composable
private fun SelectionOverlay(chart: DashboardChart, index: Int, tint: Color) {
    Canvas(Modifier.fillMaxWidth().height(140.dp)) {
        val count = chart.points.size
        if (count == 0) return@Canvas
        val categorical = chart.style != "line"
        val x = if (categorical) {
            val slot = size.width / count
            val cx = slot * (index + 0.5f)
            // Wash band over the inspected slot.
            drawRoundRect(
                color = tint.copy(alpha = 0.12f),
                topLeft = Offset(cx - maxOf(4f, slot * 0.78f) / 2, 0f),
                size = androidx.compose.ui.geometry.Size(maxOf(4f, slot * 0.78f), size.height),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(5f, 5f),
            )
            cx
        } else {
            if (count == 1) size.width / 2
            else size.width * index / (count - 1)
        }
        drawLine(
            color = tint.copy(alpha = 0.9f),
            start = Offset(x.coerceIn(1f, size.width - 1f), 0f),
            end = Offset(x.coerceIn(1f, size.width - 1f), size.height),
            strokeWidth = 2f,
        )
    }
}

@Composable
private fun InspectionPanel(snapshot: InspectionSnapshot, unit: String?) {
    val readings = snapshot.values.filter { it.kind != InspectionValue.Kind.REFERENCE }
    val reference = snapshot.values.firstOrNull { it.kind == InspectionValue.Kind.REFERENCE }
    Spacer(Modifier.height(8.dp))
    Column(
        Modifier
            .fillMaxWidth()
            .background(
                MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f),
                RoundedCornerShape(10.dp),
            )
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        snapshot.label?.let {
            Text(it, style = MaterialTheme.typography.labelLarge)
        }
        snapshot.signal?.let {
            Text(
                it.replaceFirstChar(Char::titlecase),
                style = MaterialTheme.typography.labelMedium,
                color = signalColor(it, MaterialTheme.colorScheme.onSurfaceVariant),
            )
        }
        readings.forEach { reading ->
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    reading.label ?: "Value",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    formatChartValue(reading.value, unit),
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
        reference?.let {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    it.label ?: "Reference",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    formatChartValue(it.value, unit),
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
        snapshot.comparison?.let {
            Text(
                it,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
