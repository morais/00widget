package com.zerozerowidget.hzos.ui.cards

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.zerozerowidget.hzos.data.DashboardChart
import com.zerozerowidget.hzos.ui.theme.spacing
import com.zerozerowidget.hzos.ui.uiset.UiSetIconButton
import metavrx.uiset.compose.Icon
import metavrx.uiset.compose.Text
import metavrx.uiset.compose.theme.LocalContentColors
import metavrx.uiset.compose.theme.LocalTypography
import metavrx.uiset.compose.theme.icons.Icons

/**
 * Chart plot + pointed-at readout, mirroring InspectableChartView: the plot
 * draws a selection rule at the inspected index (plus a wash band for
 * categorical styles), and a panel below lists the label, per-series or
 * range values, the reference row, and the comparison sentence.
 *
 * Three ways to pick a point, because eyes cannot hover: a pinch or tap
 * selects the point under it, the step buttons below the plot move one at
 * a time, and a controller ray's hover (Move without a press) still
 * follows the pointer. Events are never consumed, so a vertical drag
 * still scrolls the surrounding list — the pragmatic counterpart to iOS's
 * gesture arbitration.
 */
@Composable
fun InspectableChart(
    chart: DashboardChart,
    unit: String?,
    baseTint: Color,
    modifier: Modifier = Modifier
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
                // Look and Pinch never delivers hover, and recognises only
                // elements with click semantics: this makes the plot a
                // target (a pinch selects the point under it, through the
                // Press branch below) and says which point is selected.
                .semantics {
                    stateDescription = snapshot?.let { readout(it, unit) }.orEmpty()
                    onClick(label = "Select next point") {
                        selectedIndex = (selectedIndex + 1) % count
                        true
                    }
                }
                .pointerInput(chart) {
                    awaitPointerEventScope {
                        while (true) {
                            val event = awaitPointerEvent()
                            // Pinch (two pointers, on devices with no hover
                            // to give a Move): select whatever sits under
                            // the pinch centroid, exactly like hover does
                            // for a single ray. Still never consumed, so
                            // the surrounding list keeps scrolling.
                            val pressed = event.changes.filter { it.pressed }
                            val x = if (pressed.size >= 2) {
                                pressed.map { it.position.x }.average().toFloat()
                            } else {
                                event.changes.firstOrNull()?.position?.x ?: continue
                            }
                            when (event.type) {
                                PointerEventType.Move,
                                PointerEventType.Press
                                -> {
                                    val width = size.width.toFloat()
                                    if (width > 0) {
                                        selectedIndex = indexAt(
                                            chart,
                                            (x / width).coerceIn(0f, 1f)
                                        )
                                    }
                                }

                                PointerEventType.Release,
                                PointerEventType.Exit
                                -> Unit

                                // selection sticks, like iOS
                                else -> Unit
                            }
                        }
                    }
                }
        ) {
            // The selection is drawn over the plot by the plot's own node,
            // not by a second full-size Canvas (audit P6).
            Sparkline(
                chart = chart,
                baseTint = baseTint,
                modifier = Modifier
                    .matchParentSize()
                    .drawWithContent {
                        drawContent()
                        drawSelection(chart, selectedIndex, baseTint)
                    }
            )
        }
        // Stepping without hover: controllers could point, eyes cannot
        // (readiness #15). UI Set icon buttons keep a 48dp target.
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            UiSetIconButton(
                onClick = { selectedIndex = (selectedIndex - 1).coerceAtLeast(0) },
                contentDescription = "Previous point",
                enabled = selectedIndex > 0
            ) { Icon(Icons.Regular.ChevronLeft, contentDescription = null) }
            Text(
                "${selectedIndex + 1} of $count",
                style = LocalTypography.current.bodySmall,
                color = LocalContentColors.current.secondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.weight(1f)
            )
            UiSetIconButton(
                onClick = { selectedIndex = (selectedIndex + 1).coerceAtMost(count - 1) },
                contentDescription = "Next point",
                enabled = selectedIndex < count - 1
            ) { Icon(Icons.Regular.ChevronRight, contentDescription = null) }
        }
        snapshot?.let { InspectionPanel(snapshot = it, unit = unit) }
    }
}

/** The selected point in words, e.g. "Mon: 12 kW, 2 kW above target". */
private fun readout(snapshot: InspectionSnapshot, unit: String?): String {
    val reading = snapshot.values.firstOrNull { it.kind != InspectionValue.Kind.REFERENCE }
    return listOfNotNull(
        listOfNotNull(snapshot.label, reading?.let { formatChartValue(it.value, unit) }).joinToString(": "),
        snapshot.comparison
    ).joinToString(", ")
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

private fun DrawScope.drawSelection(chart: DashboardChart, index: Int, tint: Color) {
    val count = chart.points.size
    if (count == 0) return
    val categorical = chart.style != "line"
    val x = if (categorical) {
        val slot = size.width / count
        val cx = slot * (index + 0.5f)
        // Wash band over the inspected slot.
        drawRoundRect(
            color = tint.copy(alpha = 0.12f),
            topLeft = Offset(cx - maxOf(4f, slot * 0.78f) / 2, 0f),
            size = Size(maxOf(4f, slot * 0.78f), size.height),
            cornerRadius = CornerRadius(5f, 5f)
        )
        cx
    } else {
        if (count == 1) {
            size.width / 2
        } else {
            size.width * index / (count - 1)
        }
    }
    drawLine(
        color = tint.copy(alpha = 0.9f),
        start = Offset(x.coerceIn(1f, size.width - 1f), 0f),
        end = Offset(x.coerceIn(1f, size.width - 1f), size.height),
        strokeWidth = 2f
    )
}

@Composable
private fun InspectionPanel(snapshot: InspectionSnapshot, unit: String?) {
    val readings = snapshot.values.filter { it.kind != InspectionValue.Kind.REFERENCE }
    val reference = snapshot.values.firstOrNull { it.kind == InspectionValue.Kind.REFERENCE }
    Spacer(Modifier.height(spacing.small))
    Column(
        Modifier
            .fillMaxWidth()
            .background(
                LocalContentColors.current.primary.copy(alpha = 0.08f),
                RoundedCornerShape(10.dp)
            )
            .padding(spacing.medium),
        verticalArrangement = Arrangement.spacedBy(spacing.small)
    ) {
        snapshot.label?.let {
            Text(it, style = LocalTypography.current.label)
        }
        snapshot.signal?.let {
            Text(
                it.replaceFirstChar(Char::titlecase),
                style = LocalTypography.current.caption,
                color = signalColor(
                    it,
                    LocalContentColors.current.secondary,
                    isSystemInDarkTheme()
                )
            )
        }
        readings.forEach { reading ->
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    reading.label ?: "Value",
                    style = LocalTypography.current.body,
                    color = LocalContentColors.current.secondary,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    formatChartValue(reading.value, unit),
                    style = LocalTypography.current.body
                )
            }
        }
        reference?.let {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    it.label ?: "Reference",
                    style = LocalTypography.current.body,
                    color = LocalContentColors.current.secondary,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    formatChartValue(it.value, unit),
                    style = LocalTypography.current.body
                )
            }
        }
        snapshot.comparison?.let {
            Text(
                it,
                style = LocalTypography.current.bodySmall,
                color = LocalContentColors.current.secondary
            )
        }
    }
}
