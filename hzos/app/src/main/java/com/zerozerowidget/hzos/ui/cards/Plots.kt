package com.zerozerowidget.hzos.ui.cards

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import com.zerozerowidget.hzos.data.DashboardChart
import com.zerozerowidget.hzos.data.DashboardStatus
import com.zerozerowidget.hzos.data.DashboardTimeline
import com.zerozerowidget.hzos.data.MetricSemantic
import com.zerozerowidget.hzos.ui.theme.spacing
import kotlin.math.abs
import metavrx.uiset.compose.Text
import metavrx.uiset.compose.theme.LocalContentColors
import metavrx.uiset.compose.theme.LocalTypography

/**
 * Reference legend: a short length of the actual dashed rule in its own
 * color beside the label — the text alone doesn't say which line it names.
 * Same tint, opacity, and dash the plot draws.
 */
@Composable
internal fun ReferenceLegend(chart: DashboardChart, baseTint: Color, label: String) {
    val dark = isSystemInDarkTheme()
    val semantics = chart.referenceMetadata?.semantic
    val tint = semantics?.let { chartTint(0, baseTint, it, dark) } ?: chartPalette(dark).SECONDARY
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(spacing.small)
    ) {
        Canvas(Modifier.width(24.dp).height(8.dp)) {
            drawLine(
                color = tint.copy(alpha = roleOpacity(semantics?.role)),
                start = Offset(0f, size.height / 2),
                end = Offset(size.width, size.height / 2),
                strokeWidth = 2f,
                pathEffect = PathEffect.dashPathEffect(referenceDash(semantics?.role), 0f)
            )
        }
        Text(
            label,
            style = LocalTypography.current.caption,
            color = LocalContentColors.current.secondary
        )
    }
}

/** The vertical range a chart is drawn against, and whether its reference rule fits. */
internal data class ChartScale(val lo: Double, val hi: Double, val drawReference: Boolean)

/**
 * One scale for everything drawn (see SparklineView's `plotted`): points,
 * series and ranges together. An unpinned edge stretches to keep the
 * reference visible; a pinned edge with the reference outside omits the
 * rule instead.
 */
internal fun chartScale(chart: DashboardChart): ChartScale {
    val values = buildList {
        addAll(chart.points)
        chart.series?.forEach { addAll(it.points) }
        chart.ranges?.forEach {
            add(it.low)
            add(it.high)
        }
    }
    var lo = chart.min ?: values.min()
    var hi = chart.max ?: values.max()
    val ref = chart.reference
    var drawReference = ref != null
    if (ref != null) {
        if (chart.min == null) {
            lo = minOf(lo, ref)
        } else if (ref < lo) {
            drawReference = false
        }
        if (chart.max == null) {
            hi = maxOf(hi, ref)
        } else if (ref > hi) {
            drawReference = false
        }
    }
    return ChartScale(lo, hi, drawReference)
}

/**
 * Hand-rolled Canvas plot — no chart dependency, per the repo's no-new-framework
 * rule. Mirrors SparklineView's geometry branch-for-branch: one normalized
 * space for every drawn element (points, ranges, reference, zero), rounded
 * bars, translucent range columns with value ticks, dashed reference rule.
 * Panels are wide, so every point is drawn (no narrow-surface downsampling).
 *
 * @param baseTint the card's status tint — the `index: 0` palette entry,
 * falling back through signal/flow exactly like ChartSeriesPalette.
 */
@Composable
fun Sparkline(chart: DashboardChart, baseTint: Color, modifier: Modifier = Modifier) {
    val dark = isSystemInDarkTheme()
    val secondary = chartPalette(dark).SECONDARY
    val points = chart.points
    if (points.size < 2) return
    // The scale depends only on the chart, so it is worked out once per
    // chart rather than on every frame the Canvas draws (audit P6).
    val scale = remember(chart) { chartScale(chart) }
    Canvas(modifier) {
        val lo = scale.lo
        val hi = scale.hi
        val ref = chart.reference
        val drawReference = scale.drawReference
        val span = (hi - lo).takeIf { it != 0.0 } ?: 1.0
        fun y(v: Double) = size.height - ((v - lo) / span * size.height).toFloat()

        if (drawReference) {
            val semantics = chart.referenceMetadata?.semantic
            val refTint = semantics?.let { chartTint(0, baseTint, it, dark) } ?: secondary
            drawLine(
                color = refTint.copy(alpha = roleOpacity(semantics?.role)),
                start = Offset(0f, y(ref!!)),
                end = Offset(size.width, y(ref)),
                strokeWidth = 2f,
                pathEffect = PathEffect.dashPathEffect(referenceDash(semantics?.role), 0f)
            )
        }

        when (chart.style) {
            "bar" -> drawBars(chart, baseTint, secondary, dark, ::y)
            "delta" -> drawDelta(chart, baseTint, secondary, dark, lo, hi, ::y)
            "range" -> drawRanges(chart, baseTint, dark, ::y)
            else -> drawLineSeries(chart, baseTint, dark, ::y)
        }
    }
}

internal fun DrawScope.drawLineSeries(
    chart: DashboardChart,
    baseTint: Color,
    dark: Boolean,
    y: (Double) -> Float
) {
    val points = chart.points
    val tint = chartTint(0, baseTint, chart.semantic, dark)
    val opacity = roleOpacity(chart.semantic?.role)
    val xs: (Int) -> Float = { i -> size.width * i / (points.size - 1) }
    if (points.size > 1) {
        // Area wash under the line, fading top to bottom.
        val area = Path().apply {
            moveTo(xs(0), size.height)
            lineTo(xs(0), y(points[0]))
            points.forEachIndexed { i, v -> if (i > 0) lineTo(xs(i), y(v)) }
            lineTo(xs(points.size - 1), size.height)
            close()
        }
        drawPath(
            area,
            Brush.verticalGradient(
                0f to tint.copy(alpha = 0.32f * opacity),
                1f to tint.copy(alpha = 0.02f * opacity)
            )
        )
        val line = Path().apply {
            moveTo(xs(0), y(points[0]))
            points.forEachIndexed { i, v -> if (i > 0) lineTo(xs(i), y(v)) }
        }
        drawPath(
            line,
            tint.copy(alpha = opacity),
            style = Stroke(width = 4f, cap = StrokeCap.Round, join = StrokeJoin.Round)
        )
    }
}

internal fun DrawScope.drawBars(
    chart: DashboardChart,
    baseTint: Color,
    secondary: Color,
    dark: Boolean,
    y: (Double) -> Float
) {
    val count = chart.points.size
    if (count == 0) return
    val slot = size.width / count
    val series = chart.series?.takeIf { it.isNotEmpty() }
    if (series == null) {
        val tint = chartTint(0, baseTint, chart.semantic, dark)
        val alpha = 0.85f * roleOpacity(chart.semantic?.role)
        val bw = maxOf(1f, slot * 0.62f)
        val radius = minOf(2.dp.toPx(), bw / 2)
        chart.points.forEachIndexed { i, v ->
            val top = y(v).coerceIn(0f, size.height)
            drawRoundRect(
                color = tint.copy(alpha = alpha),
                topLeft = Offset(size.width / count * i + (slot - bw) / 2, minOf(size.height, top)),
                size = Size(bw, maxOf(1f, abs(size.height - top))),
                cornerRadius = CornerRadius(radius, radius)
            )
        }
        return
    }
    // Multi-series: stacked columns share an edge, grouped sit side by side.
    val semantics = series.map { s ->
        (s.semantic ?: chart.semantic)?.let {
            // Series inherits chart-level hints it omits (see types.ts).
            MetricSemantic(
                role = s.semantic?.role ?: chart.semantic?.role,
                flow = s.semantic?.flow ?: chart.semantic?.flow,
                signal = s.semantic?.signal ?: chart.semantic?.signal
            )
        }
    }
    val tints = seriesTints(semantics, dark)
    val groupWidth = slot * 0.76f
    val stacked = chart.stacking != "grouped"
    val columnWidth = if (stacked) groupWidth else maxOf(1f, groupWidth / series.size)
    val groupStart = (slot - groupWidth) / 2
    val cumulative = DoubleArray(count)
    series.forEachIndexed { si, entry ->
        val roleOp = roleOpacity(semantics[si]?.role)
        entry.points.forEachIndexed { i, v ->
            if (i >= count) return@forEachIndexed
            val lower = if (stacked) cumulative[i] else 0.0
            val upper = if (stacked) lower + v else v
            if (stacked) cumulative[i] = upper
            val lowerY = y(lower).coerceIn(0f, size.height)
            val upperY = y(upper).coerceIn(0f, size.height)
            val radius = minOf(2.dp.toPx(), columnWidth / 2)
            drawRoundRect(
                color = tints[si].copy(alpha = 0.85f * roleOp),
                topLeft = Offset(
                    size.width / count * i + groupStart + if (stacked) 0f else columnWidth * si,
                    minOf(lowerY, upperY)
                ),
                size = Size(
                    columnWidth,
                    maxOf(1f, abs(upperY - lowerY))
                ),
                cornerRadius = CornerRadius(radius, radius)
            )
        }
    }
}

internal fun DrawScope.drawDelta(
    chart: DashboardChart,
    baseTint: Color,
    secondary: Color,
    dark: Boolean,
    lo: Double,
    hi: Double,
    y: (Double) -> Float
) {
    val points = chart.points
    if (points.isEmpty()) return
    val tint = chartTint(0, baseTint, chart.semantic, dark)
    val opacity = roleOpacity(chart.semantic?.role)
    val zeroY = if (0.0 in lo..hi) y(0.0) else size.height
    val slot = size.width / points.size
    val bw = maxOf(1f, slot * 0.62f)
    val radius = minOf(2.dp.toPx(), bw / 2)
    points.forEachIndexed { i, v ->
        val valueY = y(v).coerceIn(0f, size.height)
        val above = v >= 0.0
        drawRoundRect(
            color = tint.copy(alpha = (if (above) 0.85f else 0.4f) * opacity),
            topLeft = Offset(
                size.width / points.size * i + (slot - bw) / 2,
                minOf(zeroY, valueY)
            ),
            size = Size(bw, maxOf(1f, abs(valueY - zeroY))),
            cornerRadius = CornerRadius(radius, radius)
        )
    }
    if (0.0 in lo..hi) {
        drawLine(secondary, Offset(0f, zeroY), Offset(size.width, zeroY), strokeWidth = 2f)
    }
}

/**
 * Range style: translucent floating columns per low/high interval with a
 * marker tick for each supplied value — the basement-humidity shape from
 * the iPad screenshot (0.32 column wash, full-alpha round-cap ticks at
 * 0.68 slot width). Falls back to the compatibility line when ranges are
 * absent or misaligned.
 */
internal fun DrawScope.drawRanges(
    chart: DashboardChart,
    baseTint: Color,
    dark: Boolean,
    y: (Double) -> Float
) {
    val ranges = chart.ranges?.takeIf { it.size == chart.points.size }
    if (ranges.isNullOrEmpty()) {
        drawLineSeries(chart, baseTint, dark, y)
        return
    }
    val tint = chartTint(0, baseTint, chart.semantic, dark)
    val opacity = roleOpacity(chart.semantic?.role)
    val slot = size.width / ranges.size
    val barW = maxOf(1f, slot * 0.56f)
    val radius = minOf(3.dp.toPx(), barW / 2)
    ranges.forEachIndexed { i, r ->
        val lowY = y(r.low).coerceIn(0f, size.height)
        val highY = y(r.high).coerceIn(0f, size.height)
        drawRoundRect(
            color = tint.copy(alpha = 0.32f * opacity),
            topLeft = Offset(
                size.width / ranges.size * i + (slot - barW) / 2,
                minOf(lowY, highY)
            ),
            size = Size(barW, maxOf(1f, abs(highY - lowY))),
            cornerRadius = CornerRadius(radius, radius)
        )
        r.value?.let { v ->
            val tickW = maxOf(2f, slot * 0.68f)
            val cx = size.width / ranges.size * (i + 0.5f)
            drawLine(
                color = tint.copy(alpha = opacity),
                start = Offset(cx - tickW / 2, y(v)),
                end = Offset(cx + tickW / 2, y(v)),
                strokeWidth = 4f,
                cap = StrokeCap.Round
            )
        }
    }
}

internal fun parseEpochMs(iso: String): Long? = try {
    java.time.Instant.parse(iso).toEpochMilli()
} catch (_: Exception) {
    null
}

internal fun formatHourMinute(iso: String): String = try {
    val zdt = java.time.Instant.parse(iso).atZone(java.time.ZoneId.systemDefault())
    "%02d:%02d".format(zdt.hour, zdt.minute)
} catch (_: Exception) {
    iso.take(16)
}

/**
 * Fixed-window event plot mirroring EventTimelineView: one baseline rule
 * per lane, duration spans as translucent rounded bars, instants as dots —
 * all positioned by elapsed time within [startAt, endAt], never evenly
 * spaced. [selectedFraction] draws the inspection rule (F4 hooks it up).
 */
@Composable
fun TimelinePlot(
    timeline: DashboardTimeline,
    baseTint: Color,
    selectedFraction: Float?,
    modifier: Modifier = Modifier
) {
    val dark = isSystemInDarkTheme()
    val secondary = chartPalette(dark).SECONDARY
    Canvas(modifier) {
        val start = parseEpochMs(timeline.startAt) ?: return@Canvas
        val end = parseEpochMs(timeline.endAt)?.takeIf { it > start } ?: return@Canvas
        val spanMs = (end - start).toFloat()
        fun fractionOf(iso: String): Float? = parseEpochMs(iso)?.let { ((it - start) / spanMs).coerceIn(0f, 1f) }
        val laneCount = maxOf(1, timeline.lanes.size)
        val laneH = size.height / laneCount
        // Lane baselines.
        timeline.lanes.indices.forEach { i ->
            val y = laneH * (i + 0.5f)
            drawLine(
                color = secondary.copy(alpha = 0.20f),
                start = Offset(0f, y),
                end = Offset(size.width, y),
                strokeWidth = 2f
            )
        }
        fun laneOf(laneId: String): Int = timeline.lanes.indexOfFirst { it.id == laneId }
        fun seriesTintOf(seriesId: String, status: DashboardStatus): Color {
            status.takeIf { it != DashboardStatus.UNKNOWN }
                ?.let { return statusColor(it, secondary, dark) }
            val si = timeline.series.indexOfFirst { it.id == seriesId }.takeIf { it >= 0 } ?: 0
            return chartTint(si, baseTint, null, dark)
        }
        // Duration spans first, instant markers over them.
        timeline.entries.forEach { e ->
            val endAt = e.endAt ?: return@forEach
            val lane = laneOf(e.laneId).takeIf { it >= 0 } ?: return@forEach
            val x1 = fractionOf(e.at) ?: return@forEach
            val x2 = fractionOf(endAt) ?: return@forEach
            val barH = maxOf(4.dp.toPx(), laneH * 0.62f)
            val radius = minOf(3.dp.toPx(), barH / 3)
            drawRoundRect(
                color = seriesTintOf(e.seriesId, e.status).copy(alpha = 0.24f),
                topLeft = Offset(x1 * size.width, laneH * (lane + 0.5f) - barH / 2),
                size = Size(maxOf(2f, (x2 - x1) * size.width), barH),
                cornerRadius = CornerRadius(radius, radius)
            )
        }
        timeline.entries.forEach { e ->
            if (e.endAt != null) return@forEach
            val lane = laneOf(e.laneId).takeIf { it >= 0 } ?: return@forEach
            val rawX = fractionOf(e.at) ?: return@forEach
            val r = minOf(maxOf(5f, laneH * 0.42f), 11f) / 2
            val x = rawX * size.width
            drawCircle(
                color = seriesTintOf(e.seriesId, e.status),
                radius = r,
                center = Offset(x.coerceIn(r, maxOf(r, size.width - r)), laneH * (lane + 0.5f))
            )
        }
        selectedFraction?.let { f ->
            val x = (f * size.width).coerceIn(1f, size.width - 1f)
            drawLine(
                color = baseTint.copy(alpha = 0.9f),
                start = Offset(x, 0f),
                end = Offset(x, size.height),
                strokeWidth = 2f
            )
        }
    }
}
