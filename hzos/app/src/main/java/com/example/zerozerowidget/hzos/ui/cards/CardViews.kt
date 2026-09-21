package com.example.zerozerowidget.hzos.ui.cards

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.example.zerozerowidget.hzos.data.ActionDefinition
import com.example.zerozerowidget.hzos.data.DashboardCard
import com.example.zerozerowidget.hzos.data.DashboardChart
import com.example.zerozerowidget.hzos.data.DashboardStatus
import com.example.zerozerowidget.hzos.data.isSample
import kotlin.math.abs

/** See ChartColors.kt: statusColor now mirrors DashboardStatus.tint. */

@Composable
fun StatusDot(status: DashboardStatus, modifier: Modifier = Modifier) {
    val unknown = MaterialTheme.colorScheme.onSurfaceVariant
    Canvas(modifier = modifier.size(10.dp)) {
        drawCircle(statusColor(status, unknown))
    }
}

/**
 * Demo-data pill. Solid primary lozenge, white text, fixed padding — an
 * inline element that can sit anywhere a label sits, so it never disturbs
 * the surrounding layout (no rotation, no overflow, no offsets).
 */
@Composable
fun SampleBadge(modifier: Modifier = Modifier) {    Box(
        modifier = modifier
            .background(
                MaterialTheme.colorScheme.primary,
                androidx.compose.foundation.shape.RoundedCornerShape(4.dp),
            )
            .padding(horizontal = 6.dp, vertical = 2.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            "SAMPLE",
            style = MaterialTheme.typography.labelSmall,
            color = Color.White,
        )
    }
}

/**
 * Demo-data banner. Same pill pattern at full width: primary background,
 * white text, iOS wording verbatim ("These are samples" + the generated-
 * on-device sentence + "Remove sample widgets"). Answers the user's
 * question directly: no, "This is sample data" was ours — this is iOS's.
 */
@Composable
fun SampleNoticeBanner(onRemoveAll: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(
                MaterialTheme.colorScheme.primary,
                androidx.compose.foundation.shape.RoundedCornerShape(8.dp),
            )
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                "These are samples",
                style = MaterialTheme.typography.titleSmall,
                color = Color.White,
            )
            Text(
                "Sample widgets are generated on this device to show what 00Widget looks like. No agent published them.",
                style = MaterialTheme.typography.bodySmall,
                color = Color.White,
            )
        }
        Button(
            onClick = onRemoveAll,
            colors = ButtonDefaults.buttonColors(
                containerColor = Color.White,
                contentColor = MaterialTheme.colorScheme.primary,
            ),
        ) {
            Text("Remove samples", style = MaterialTheme.typography.labelMedium)
        }
    }
}

/**
 * Pop-out affordance drawn with Canvas strokes, never a font glyph — the
 * headset font lacks symbols like U+279A, which rendered prior icon
 * buttons invisible. Open-in-new shape: box with an arrow leaving top-right.
 */
@Composable
fun PopOutIconButton(onPopOut: () -> Unit, modifier: Modifier = Modifier) {
    IconButton(onClick = onPopOut, modifier = modifier) {
        val color = MaterialTheme.colorScheme.onSurfaceVariant
        Canvas(Modifier.size(22.dp)) {
            val sw = 2.dp.toPx()
            // Box outline; the arrow overlaps its top-right corner.
            drawRoundRect(
                color = color,
                topLeft = Offset(3.dp.toPx(), 8.dp.toPx()),
                size = Size(12.dp.toPx(), 11.dp.toPx()),
                cornerRadius = CornerRadius(3.dp.toPx(), 3.dp.toPx()),
                style = Stroke(width = sw),
            )
            // Arrow leaving toward top-right.
            val tip = Offset(19.dp.toPx(), 5.dp.toPx())
            drawLine(color, Offset(9.dp.toPx(), 15.dp.toPx()), tip, strokeWidth = sw, cap = StrokeCap.Round)
            drawLine(color, tip, Offset(tip.x - 4.5.dp.toPx(), tip.y), strokeWidth = sw, cap = StrokeCap.Round)
            drawLine(color, tip, Offset(tip.x, tip.y + 4.5.dp.toPx()), strokeWidth = sw, cap = StrokeCap.Round)
        }
    }
}

/** One-line headline used in the dashboard list for every template. */
@Composable
fun CardHeadline(card: DashboardCard, modifier: Modifier = Modifier) {
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically) {
        StatusDot(card.status)
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(
                card.title,
                style = MaterialTheme.typography.titleSmall,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            val headline = listOfNotNull(card.value?.let { it + (card.unit?.let { u -> " $u" } ?: "") })
                .firstOrNull()
            if (headline != null) {
                Text(
                    headline,
                    style = MaterialTheme.typography.bodyLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        card.progress?.let {
            Text(
                "${(it * 100).toInt()}%",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/**
 * Full template body for the detail surface. Every [DashboardTemplate] has a
 * branch — the Swift `switch`es fail the build when one is missed; here the
 * `else` + comment below is the backstop, so check it when adding a template.
 */
@Composable
fun CardTemplateBody(card: DashboardCard, modifier: Modifier = Modifier, interactiveCharts: Boolean = false) {
    Column(modifier) {
        when (card.template) {
            com.example.zerozerowidget.hzos.data.DashboardTemplate.SUMMARY -> SummaryBody(card)
            com.example.zerozerowidget.hzos.data.DashboardTemplate.PROGRESS -> ProgressBody(card)
            com.example.zerozerowidget.hzos.data.DashboardTemplate.LIST -> ListBody(card)
            com.example.zerozerowidget.hzos.data.DashboardTemplate.ACTION -> ActionHintBody()
            com.example.zerozerowidget.hzos.data.DashboardTemplate.CHART -> ChartBody(card, interactiveCharts)
            com.example.zerozerowidget.hzos.data.DashboardTemplate.HISTORY -> HistoryBody(card)
            com.example.zerozerowidget.hzos.data.DashboardTemplate.BREAKDOWN -> BreakdownBody(card)
            com.example.zerozerowidget.hzos.data.DashboardTemplate.BRIEFING -> BriefingBody(card)
            com.example.zerozerowidget.hzos.data.DashboardTemplate.TIMELINE -> TimelineBody(card)
        }
        // Buttons combine with any template (llms.md) but need the action
        // runner, which lives on the calling surface (dashboard / detail via
        // ActionButtons) — so this shared body renders no buttons itself.
    }
}

@Composable
private fun CardMetaLine(card: DashboardCard) {
    card.subtitle?.let {
        Text(it, style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        card.producer?.let {
            Text(
                it.label,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
        }
        card.comparison?.let {
            Text(
                "${it.value} ${it.label}",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun SummaryBody(card: DashboardCard) {
    CardMetaLine(card)
}

@Composable
private fun ProgressBody(card: DashboardCard) {
    CardMetaLine(card)
    Spacer(Modifier.height(8.dp))
    LinearProgressIndicator(
        progress = { (card.progress ?: 0.0).toFloat() },
        modifier = Modifier.fillMaxWidth(),
    )
    card.value?.let {
        Spacer(Modifier.height(4.dp))
        Text(it, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun ListBody(card: DashboardCard) {
    CardMetaLine(card)
    Spacer(Modifier.height(4.dp))
    val items = card.items.orEmpty()
    val max = items.mapNotNull { it.amount }.maxOrNull()?.takeIf { it > 0 }
    items.forEach { item ->
        Column(Modifier.fillMaxWidth().padding(vertical = 3.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                StatusDot(item.status, Modifier.padding(end = 6.dp))
                Text(
                    item.title,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                item.value?.let {
                    Text(
                        it + (item.unit?.let { u -> " $u" } ?: ""),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            // Ranked bars when rows carry an amount (mirrors the iOS list).
            if (max != null && item.amount != null) {
                Spacer(Modifier.height(2.dp))
                LinearProgressIndicator(
                    progress = { (item.amount / max).toFloat().coerceIn(0f, 1f) },
                    modifier = Modifier.fillMaxWidth().height(4.dp),
                )
            }
            item.subtitle?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun ActionHintBody() {
    Text(
        "Buttons are below.",
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun ChartBody(card: DashboardCard, interactive: Boolean) {
    CardMetaLine(card)
    val chart = card.chart ?: return
    Spacer(Modifier.height(8.dp))
    // Base tint is the card's status tint, exactly like iOS (SparklineView
    // takes the card tint as its `tint` argument).
    val unknown = MaterialTheme.colorScheme.onSurfaceVariant
    val base = statusColor(card.status, unknown)
    if (interactive) {
        InspectableChart(
            chart = chart,
            unit = card.unit,
            baseTint = base,
            modifier = Modifier.fillMaxWidth(),
        )
    } else {
        Sparkline(
            chart = chart,
            baseTint = base,
            modifier = Modifier.fillMaxWidth().height(120.dp),
        )
    }
    chart.referenceMetadata?.label?.let {
        Text(it, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
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
    val secondary = IosChartColors.SECONDARY
    val points = chart.points
    if (points.size < 2) return
    Canvas(modifier) {
        // One scale for everything drawn (see SparklineView's `plotted`).
        val dataMin = buildList {
            add(points.min())
            chart.series?.forEach { s -> s.points.minOrNull()?.let(::add) }
            chart.ranges?.forEach { add(it.low); add(it.high) }
        }.min()
        val dataMax = buildList {
            add(points.max())
            chart.series?.forEach { s -> s.points.maxOrNull()?.let(::add) }
            chart.ranges?.forEach { add(it.low); add(it.high) }
        }.max()
        var lo = chart.min ?: dataMin
        var hi = chart.max ?: dataMax
        // An unpinned edge stretches to keep the reference visible; a pinned
        // edge with the reference outside omits the rule instead.
        val ref = chart.reference
        var drawReference = ref != null
        if (ref != null) {
            if (chart.min == null) lo = minOf(lo, ref)
            else if (ref < lo) drawReference = false
            if (chart.max == null) hi = maxOf(hi, ref)
            else if (ref > hi) drawReference = false
        }
        val span = (hi - lo).takeIf { it != 0.0 } ?: 1.0
        fun y(v: Double) = size.height - ((v - lo) / span * size.height).toFloat()

        if (drawReference) {
            val semantics = chart.referenceMetadata?.semantic
            val refTint = semantics?.let { chartTint(0, baseTint, it) } ?: secondary
            drawLine(
                color = refTint.copy(alpha = roleOpacity(semantics?.role)),
                start = Offset(0f, y(ref!!)),
                end = Offset(size.width, y(ref)),
                strokeWidth = 2f,
                pathEffect = PathEffect.dashPathEffect(referenceDash(semantics?.role), 0f),
            )
        }

        when (chart.style) {
            "bar" -> drawBars(chart, baseTint, secondary, ::y)
            "delta" -> drawDelta(chart, baseTint, secondary, lo, hi, ::y)
            "range" -> drawRanges(chart, baseTint, ::y)
            else -> drawLineSeries(chart, baseTint, ::y)
        }
    }
}

private fun DrawScope.drawLineSeries(
    chart: DashboardChart,
    baseTint: Color,
    y: (Double) -> Float,
) {
    val points = chart.points
    val tint = chartTint(0, baseTint, chart.semantic)
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
                1f to tint.copy(alpha = 0.02f * opacity),
            ),
        )
        val line = Path().apply {
            moveTo(xs(0), y(points[0]))
            points.forEachIndexed { i, v -> if (i > 0) lineTo(xs(i), y(v)) }
        }
        drawPath(
            line,
            tint.copy(alpha = opacity),
            style = Stroke(width = 4f, cap = StrokeCap.Round, join = StrokeJoin.Round),
        )
    }
}

private fun DrawScope.drawBars(
    chart: DashboardChart,
    baseTint: Color,
    secondary: Color,
    y: (Double) -> Float,
) {
    val count = chart.points.size
    if (count == 0) return
    val slot = size.width / count
    val series = chart.series?.takeIf { it.isNotEmpty() }
    if (series == null) {
        val tint = chartTint(0, baseTint, chart.semantic)
        val alpha = 0.85f * roleOpacity(chart.semantic?.role)
        val bw = maxOf(1f, slot * 0.62f)
        val radius = minOf(2.dp.toPx(), bw / 2)
        chart.points.forEachIndexed { i, v ->
            val top = y(v).coerceIn(0f, size.height)
            drawRoundRect(
                color = tint.copy(alpha = alpha),
                topLeft = Offset(size.width / count * i + (slot - bw) / 2, minOf(size.height, top)),
                size = androidx.compose.ui.geometry.Size(bw, maxOf(1f, abs(size.height - top))),
                cornerRadius = CornerRadius(radius, radius),
            )
        }
        return
    }
    // Multi-series: stacked columns share an edge, grouped sit side by side.
    val semantics = series.map { s ->
        (s.semantic ?: chart.semantic)?.let {
            // Series inherits chart-level hints it omits (see types.ts).
            com.example.zerozerowidget.hzos.data.MetricSemantic(
                role = s.semantic?.role ?: chart.semantic?.role,
                flow = s.semantic?.flow ?: chart.semantic?.flow,
                signal = s.semantic?.signal ?: chart.semantic?.signal,
            )
        }
    }
    val tints = seriesTints(semantics)
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
                    minOf(lowerY, upperY),
                ),
                size = androidx.compose.ui.geometry.Size(
                    columnWidth,
                    maxOf(1f, abs(upperY - lowerY)),
                ),
                cornerRadius = CornerRadius(radius, radius),
            )
        }
    }
}

private fun DrawScope.drawDelta(
    chart: DashboardChart,
    baseTint: Color,
    secondary: Color,
    lo: Double,
    hi: Double,
    y: (Double) -> Float,
) {
    val points = chart.points
    if (points.isEmpty()) return
    val tint = chartTint(0, baseTint, chart.semantic)
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
                minOf(zeroY, valueY),
            ),
            size = androidx.compose.ui.geometry.Size(bw, maxOf(1f, abs(valueY - zeroY))),
            cornerRadius = CornerRadius(radius, radius),
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
private fun DrawScope.drawRanges(
    chart: DashboardChart,
    baseTint: Color,
    y: (Double) -> Float,
) {
    val ranges = chart.ranges?.takeIf { it.size == chart.points.size }
    if (ranges.isNullOrEmpty()) {
        drawLineSeries(chart, baseTint, y)
        return
    }
    val tint = chartTint(0, baseTint, chart.semantic)
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
                minOf(lowY, highY),
            ),
            size = androidx.compose.ui.geometry.Size(barW, maxOf(1f, abs(highY - lowY))),
            cornerRadius = CornerRadius(radius, radius),
        )
        r.value?.let { v ->
            val tickW = maxOf(2f, slot * 0.68f)
            val cx = size.width / ranges.size * (i + 0.5f)
            drawLine(
                color = tint.copy(alpha = opacity),
                start = Offset(cx - tickW / 2, y(v)),
                end = Offset(cx + tickW / 2, y(v)),
                strokeWidth = 4f,
                cap = StrokeCap.Round,
            )
        }
    }
}

@Composable
private fun HistoryBody(card: DashboardCard) {
    CardMetaLine(card)
    Spacer(Modifier.height(8.dp))
    // Outcome pips, oldest first, most recent on the right (mirrors iOS).
    val unknown = MaterialTheme.colorScheme.onSurfaceVariant
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        card.items.orEmpty().forEach { item ->
            Canvas(Modifier.size(14.dp)) { drawCircle(statusColor(item.status, unknown)) }
        }
    }
    Spacer(Modifier.height(4.dp))
    card.items.orEmpty().takeLast(5).reversed().forEach { item ->
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(item.title, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
            item.value?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun BreakdownBody(card: DashboardCard) {
    CardMetaLine(card)
    Spacer(Modifier.height(8.dp))
    val items = card.items.orEmpty()
    val total = items.sumOf { (it.amount ?: 0.0).coerceAtLeast(0.0) }.takeIf { it > 0 } ?: return
    Canvas(Modifier.fillMaxWidth().height(18.dp)) {
        var acc = 0.0
        val palette = listOf(Color(0xFF7DD3FC), Color(0xFFA5B4FC), Color(0xFF6EE7B7), Color(0xFFFCD34D), Color(0xFFF9A8D4))
        val unknown = Color(0xFFB9C2CC)
        items.forEachIndexed { i, item ->
            val share = (item.amount ?: 0.0).coerceAtLeast(0.0) / total
            val left = (acc / total * size.width).toFloat()
            acc += (item.amount ?: 0.0).coerceAtLeast(0.0)
            val right = (acc / total * size.width).toFloat()
            val color = when (item.status) {
                DashboardStatus.UNKNOWN -> palette[i % palette.size]
                else -> statusColor(item.status, unknown)
            }
            drawRect(color, Offset(left, 0f), androidx.compose.ui.geometry.Size(right - left, size.height))
        }
    }
    items.forEach { item ->
        Row(Modifier.fillMaxWidth()) {
            Text(item.title, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
            item.value?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun BriefingBody(card: DashboardCard) {
    CardMetaLine(card)
    Spacer(Modifier.height(4.dp))
    card.briefing?.sections.orEmpty().forEach { section ->
        section.label?.let {
            Text(it, style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 6.dp))
        }
        Text(section.text, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun TimelineBody(card: DashboardCard) {
    CardMetaLine(card)
    val timeline = card.timeline ?: return
    val unknown = MaterialTheme.colorScheme.onSurfaceVariant
    val base = statusColor(card.status, unknown)
    Spacer(Modifier.height(4.dp))
    // Legend: series dot + label. FlowRow wraps long label sets onto
    // multiple lines instead of pushing the plot off the panel.
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        timeline.series.take(4).forEachIndexed { index, series ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Canvas(Modifier.size(7.dp)) {
                    drawCircle(chartTint(index, base, null))
                }
                Text(
                    series.label,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
            }
        }
    }
    Spacer(Modifier.height(6.dp))
    Row {
        if (timeline.lanes.size > 1) {
            Column(Modifier.width(72.dp)) {
                timeline.lanes.forEach { lane ->
                    Box(
                        Modifier.fillMaxWidth().weight(1f),
                        contentAlignment = Alignment.CenterEnd,
                    ) {
                        Text(
                            lane.label,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                        )
                    }
                }
            }
            Spacer(Modifier.width(6.dp))
        }
        TimelinePlot(
            timeline = timeline,
            baseTint = base,
            selectedFraction = null,
            modifier = Modifier.weight(1f).height(120.dp),
        )
    }
    Spacer(Modifier.height(4.dp))
    Row(Modifier.fillMaxWidth()) {
        Text(
            formatHourMinute(timeline.startAt),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.weight(1f))
        Text(
            formatHourMinute(timeline.endAt),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

private fun parseEpochMs(iso: String): Long? = try {
    java.time.Instant.parse(iso).toEpochMilli()
} catch (_: Exception) {
    null
}

private fun formatHourMinute(iso: String): String = try {
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
    timeline: com.example.zerozerowidget.hzos.data.DashboardTimeline,
    baseTint: Color,
    selectedFraction: Float?,
    modifier: Modifier = Modifier,
) {
    val secondary = IosChartColors.SECONDARY
    Canvas(modifier) {
        val start = parseEpochMs(timeline.startAt) ?: return@Canvas
        val end = parseEpochMs(timeline.endAt)?.takeIf { it > start } ?: return@Canvas
        val spanMs = (end - start).toFloat()
        fun fractionOf(iso: String): Float? =
            parseEpochMs(iso)?.let { ((it - start) / spanMs).coerceIn(0f, 1f) }
        val laneCount = maxOf(1, timeline.lanes.size)
        val laneH = size.height / laneCount
        // Lane baselines.
        timeline.lanes.indices.forEach { i ->
            val y = laneH * (i + 0.5f)
            drawLine(
                color = secondary.copy(alpha = 0.20f),
                start = Offset(0f, y),
                end = Offset(size.width, y),
                strokeWidth = 2f,
            )
        }
        fun laneOf(laneId: String): Int =
            timeline.lanes.indexOfFirst { it.id == laneId }
        fun seriesTintOf(seriesId: String, status: com.example.zerozerowidget.hzos.data.DashboardStatus): Color {
            status.takeIf { it != com.example.zerozerowidget.hzos.data.DashboardStatus.UNKNOWN }
                ?.let { return statusColor(it, secondary) }
            val si = timeline.series.indexOfFirst { it.id == seriesId }.takeIf { it >= 0 } ?: 0
            return chartTint(si, baseTint, null)
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
                size = androidx.compose.ui.geometry.Size(maxOf(2f, (x2 - x1) * size.width), barH),
                cornerRadius = CornerRadius(radius, radius),
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
                center = Offset(x.coerceIn(r, maxOf(r, size.width - r)), laneH * (lane + 0.5f)),
            )
        }
        selectedFraction?.let { f ->
            val x = (f * size.width).coerceIn(1f, size.width - 1f)
            drawLine(
                color = baseTint.copy(alpha = 0.9f),
                start = Offset(x, 0f),
                end = Offset(x, size.height),
                strokeWidth = 2f,
            )
        }
    }
}

/** Safe action button with in-flight + error state. Unsafe actions render as a note, never a button. */
@Composable
fun ActionButtons(
    card: DashboardCard,
    onRun: (ActionDefinition) -> Unit,
    runningId: String?,
    runError: String?,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        card.actions.orEmpty().forEach { action ->
            if (action.isSafeFromPanel) {
                Button(
                    onClick = { onRun(action) },
                    enabled = runningId == null,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(if (runningId == action.id) "Running…" else action.label)
                }
            } else {
                FilledTonalButton(onClick = {}, enabled = false, modifier = Modifier.fillMaxWidth()) {
                    Text("${action.label} — confirm in app")
                }
            }
        }
        runError?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
        }
    }
}

/**
 * Shared glass container: the same surfaceVariant + cardAlpha + onSurface
 * surface every card uses, for non-card content (settings bodies, detail
 * wrappers) that should read as the same object family.
 */
@Composable
fun GlassCard(
    cardAlpha: Float,
    modifier: Modifier = Modifier,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = cardAlpha),
            contentColor = MaterialTheme.colorScheme.onSurface,
        ),
        modifier = modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp), content = content)
    }
}
@Composable
fun DetailCard(card: DashboardCard, cardAlpha: Float, interactiveCharts: Boolean = false) {
    // Overlay badge, not layout — see DashboardRow.
    Box(Modifier.fillMaxWidth()) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = cardAlpha),
            // Explicit: see DashboardRow — alpha breaks contentColorFor().
            contentColor = MaterialTheme.colorScheme.onSurface,
        ),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp)) {
            CardHeadline(card)
            Spacer(Modifier.height(8.dp))
            CardTemplateBody(card, interactiveCharts = interactiveCharts)
        }
    }
        if (card.isSample()) {
            SampleBadge(
                Modifier
                    .align(Alignment.BottomEnd)
                    .padding(8.dp),
            )
        }
    }
}

/**
 * Delete affordance shared by card and activity detail panels. Samples
 * always read "Remove sample" (local removal); server items use the
 * caller's label ("Delete", "End activity"). One place owns the wording
 * so the two panels cannot drift apart.
 */
@Composable
fun SampleAwareDeleteRow(
    isSample: Boolean,
    serverLabel: String,
    busy: Boolean,
    error: String?,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
) {
    DeleteRow(
        label = if (isSample) "Remove sample" else serverLabel,
        busy = busy,
        error = error,
        onDelete = onDelete,
        modifier = modifier,
    )
}

/**
 * Destructive action with inline two-tap confirm, iOS detail-screen style.
 * Compact and right-aligned: a small red-tonal button, never a full-width
 * banner. First tap arms ("Sure?"), second fires.
 */
@Composable
fun DeleteRow(
    label: String,
    busy: Boolean,
    error: String?,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var armed by remember { mutableStateOf(false) }
    Column(modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            FilledTonalButton(
                onClick = {
                    if (armed) {
                        armed = false
                        onDelete()
                    } else {
                        armed = true
                    }
                },
                enabled = !busy,
                colors = ButtonDefaults.filledTonalButtonColors(
                    containerColor = MaterialTheme.colorScheme.error.copy(alpha = 0.85f),
                    contentColor = Color.White,
                ),
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp),
                modifier = Modifier.height(34.dp),
            ) {
                Text(
                    if (busy) "Working…" else if (armed) "Sure?" else label,
                    style = MaterialTheme.typography.labelMedium,
                )
            }
        }
        error?.let {
            Spacer(Modifier.height(4.dp))
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
        }
    }
}

@Composable
fun NeedsYouBadge(modifier: Modifier = Modifier) {    // Mirrors the derived "Needs you" rule in llms.md: attention status +
    // actionable button. Callers decide; this only draws the pill.
    FilledTonalButton(onClick = {}, modifier = modifier) {
        Text("Needs you", color = MaterialTheme.colorScheme.error)
    }
}
