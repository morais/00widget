package com.example.zerozerowidget.hzos.ui.cards

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.example.zerozerowidget.hzos.data.ActionDefinition
import com.example.zerozerowidget.hzos.data.DashboardCard
import com.example.zerozerowidget.hzos.data.DashboardChart
import com.example.zerozerowidget.hzos.data.DashboardStatus

/**
 * Status tint, mirroring the iOS card tint + tvOS chip derivation.
 *
 * Plain function (not @Composable) on purpose: it is called from Canvas
 * draw scopes, where composition is unavailable. Callers pass the
 * "unknown" color from a @Composable context.
 */
fun statusColor(status: DashboardStatus, unknown: Color): Color = when (status) {
    DashboardStatus.GOOD -> Color(0xFF4ADE80)
    DashboardStatus.WARNING -> Color(0xFFFBBF24)
    DashboardStatus.CRITICAL -> Color(0xFFF87171)
    DashboardStatus.RUNNING -> Color(0xFF60A5FA)
    DashboardStatus.FINISHED -> Color(0xFF94A3B8)
    DashboardStatus.PAUSED -> Color(0xFFFACC15)
    DashboardStatus.OFFLINE -> Color(0xFF64748B)
    DashboardStatus.UNKNOWN -> unknown
}

@Composable
fun StatusDot(status: DashboardStatus, modifier: Modifier = Modifier) {
    val unknown = MaterialTheme.colorScheme.onSurfaceVariant
    Canvas(modifier = modifier.size(10.dp)) {
        drawCircle(statusColor(status, unknown))
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
fun CardTemplateBody(card: DashboardCard, modifier: Modifier = Modifier) {
    Column(modifier) {
        when (card.template) {
            com.example.zerozerowidget.hzos.data.DashboardTemplate.SUMMARY -> SummaryBody(card)
            com.example.zerozerowidget.hzos.data.DashboardTemplate.PROGRESS -> ProgressBody(card)
            com.example.zerozerowidget.hzos.data.DashboardTemplate.LIST -> ListBody(card)
            com.example.zerozerowidget.hzos.data.DashboardTemplate.ACTION -> ActionHintBody()
            com.example.zerozerowidget.hzos.data.DashboardTemplate.CHART -> ChartBody(card)
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
private fun ChartBody(card: DashboardCard) {
    CardMetaLine(card)
    val chart = card.chart ?: return
    Spacer(Modifier.height(8.dp))
    Sparkline(chart, Modifier.fillMaxWidth().height(120.dp))
    chart.referenceMetadata?.label?.let {
        Text(it, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/**
 * Hand-rolled Canvas plot — no chart dependency, per the repo's no-new-framework
 * rule. Draws the compatibility `points` series (the server derives totals for
 * multi-series / ranges, so one truthful line always exists) plus the dashed
 * reference rule. Narrow-surface downsampling is unnecessary here: panels are
 * wide, so every point is drawn.
 */
@Composable
fun Sparkline(chart: DashboardChart, modifier: Modifier = Modifier) {
    val line = MaterialTheme.colorScheme.primary
    val ref = MaterialTheme.colorScheme.onSurfaceVariant
    val points = chart.points
    if (points.size < 2) return
    Canvas(modifier) {
        val lo = chart.min ?: points.min()
        val hi = chart.max ?: points.max()
        val span = (hi - lo).takeIf { it != 0.0 } ?: 1.0
        fun x(i: Int) = size.width * i / (points.size - 1)
        fun y(v: Double) = size.height - ((v - lo) / span * size.height).toFloat()
        if (chart.style == "bar" || chart.style == "delta") {
            val zeroY = when {
                chart.style != "delta" -> size.height
                0.0 in lo..hi -> y(0.0)
                else -> size.height
            }
            val bw = size.width / points.size * 0.6f
            points.forEachIndexed { i, v ->
                val top = y(v).coerceIn(0f, size.height)
                drawLine(line, Offset(x(i), zeroY), Offset(x(i), top), strokeWidth = bw)
            }
            if (chart.style == "delta" && 0.0 in lo..hi) {
                drawLine(ref, Offset(0f, zeroY), Offset(size.width, zeroY), strokeWidth = 2f)
            }
        } else {
            val path = Path().apply {
                moveTo(x(0), y(points[0]))
                points.forEachIndexed { i, v -> if (i > 0) lineTo(x(i), y(v)) }
            }
            drawPath(path, line, style = Stroke(width = 4f))
        }
        chart.reference?.let { r ->
            if (r in lo..hi) {
                val ry = y(r)
                var dx = 0f
                while (dx < size.width) {
                    drawLine(ref, Offset(dx, ry), Offset((dx + 10f).coerceAtMost(size.width), ry), strokeWidth = 2f)
                    dx += 18f
                }
            }
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
    Spacer(Modifier.height(4.dp))
    val timeline = card.timeline ?: return
    timeline.entries.take(12).forEach { entry ->
        Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
            StatusDot(entry.status, Modifier.padding(end = 6.dp))
            Text(
                entry.label ?: timeline.series.firstOrNull { it.id == entry.seriesId }?.label.orEmpty(),
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
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
                OutlinedButton(onClick = {}, enabled = false, modifier = Modifier.fillMaxWidth()) {
                    Text("${action.label} — confirm in app")
                }
            }
        }
        runError?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
        }
    }
}

@Composable
fun DetailCard(card: DashboardCard, cardAlpha: Float) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = cardAlpha),
        ),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp)) {
            CardHeadline(card)
            Spacer(Modifier.height(8.dp))
            CardTemplateBody(card)
        }
    }
}

@Composable
fun NeedsYouBadge(modifier: Modifier = Modifier) {
    // Mirrors the derived "Needs you" rule in llms.md: attention status +
    // actionable button. Callers decide; this only draws the pill.
    TextButton(onClick = {}, modifier = modifier) {
        Text("Needs you", color = MaterialTheme.colorScheme.error)
    }
}
