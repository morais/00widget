package com.zerozerowidget.hzos.ui.cards

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.zerozerowidget.hzos.data.DashboardCard
import com.zerozerowidget.hzos.data.DashboardStatus
import com.zerozerowidget.hzos.data.DashboardTemplate
import com.zerozerowidget.hzos.ui.theme.spacing
import metavrx.uiset.compose.Text
import metavrx.uiset.compose.theme.LocalContentColors
import metavrx.uiset.compose.theme.LocalTypography

/** One-line headline used in the dashboard list for every template. */
@Composable
fun CardHeadline(card: DashboardCard, modifier: Modifier = Modifier) {
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically) {
        StatusDot(card.status)
        Spacer(Modifier.width(spacing.small))
        Column(Modifier.weight(1f)) {
            Text(
                card.title,
                style = LocalTypography.current.title,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            val headline = listOfNotNull(
                card.value?.let {
                    it +
                        (card.unit?.let { u -> " $u" } ?: "")
                }
            )
                .firstOrNull()
            if (headline != null) {
                Text(
                    headline,
                    style = LocalTypography.current.bodyStrong,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
        card.progress?.let {
            Text(
                "${(it * 100).toInt()}%",
                style = LocalTypography.current.label,
                color = LocalContentColors.current.secondary
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
fun CardTemplateBody(
    card: DashboardCard,
    modifier: Modifier = Modifier,
    interactiveCharts: Boolean = false
) {
    Column(modifier) {
        when (card.template) {
            DashboardTemplate.SUMMARY -> SummaryBody(card)
            DashboardTemplate.PROGRESS -> ProgressBody(card)
            DashboardTemplate.LIST -> ListBody(card)
            DashboardTemplate.ACTION -> ActionHintBody(card, interactiveCharts)
            DashboardTemplate.CHART -> ChartBody(card, interactiveCharts)
            DashboardTemplate.HISTORY -> HistoryBody(card)
            DashboardTemplate.BREAKDOWN -> BreakdownBody(card)
            DashboardTemplate.BRIEFING -> BriefingBody(card)
            DashboardTemplate.TIMELINE -> TimelineBody(card)
        }
        // Buttons combine with any template (llms.md) but need the action
        // runner, which lives on the calling surface (dashboard / detail via
        // ActionButtons) — so this shared body renders no buttons itself.
    }
}

@Composable
internal fun CardMetaLine(card: DashboardCard) {
    card.subtitle?.let {
        Text(
            it,
            style = LocalTypography.current.body,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis
        )
    }
    Row(horizontalArrangement = Arrangement.spacedBy(spacing.small)) {
        card.producer?.let {
            Text(
                it.label,
                style = LocalTypography.current.caption,
                color = LocalContentColors.current.secondary,
                maxLines = 1
            )
        }
        card.comparison?.let {
            Text(
                "${it.value} ${it.label}",
                style = LocalTypography.current.caption,
                color = LocalContentColors.current.secondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

@Composable
internal fun SummaryBody(card: DashboardCard) {
    CardMetaLine(card)
}

@Composable
internal fun ProgressBody(card: DashboardCard) {
    CardMetaLine(card)
    Spacer(Modifier.height(spacing.small))
    ProgressBar(
        fraction = (card.progress ?: 0.0).toFloat(),
        modifier = Modifier.fillMaxWidth()
    )
    card.value?.let {
        Spacer(Modifier.height(spacing.xSmall))
        Text(it, style = LocalTypography.current.body)
    }
}

@Composable
internal fun ListBody(card: DashboardCard) {
    CardMetaLine(card)
    Spacer(Modifier.height(spacing.xSmall))
    val items = card.items.orEmpty()
    val max = items.mapNotNull { it.amount }.maxOrNull()?.takeIf { it > 0 }
    items.forEach { item ->
        Column(Modifier.fillMaxWidth().padding(vertical = 3.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                StatusDot(item.status, Modifier.padding(end = spacing.small))
                Text(
                    item.title,
                    style = LocalTypography.current.body,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                item.value?.let {
                    Text(
                        it + (item.unit?.let { u -> " $u" } ?: ""),
                        style = LocalTypography.current.body,
                        color = LocalContentColors.current.secondary
                    )
                }
            }
            // Ranked bars when rows carry an amount (mirrors the iOS list).
            if (max != null && item.amount != null) {
                Spacer(Modifier.height(2.dp))
                ProgressBar(
                    fraction = (item.amount / max).toFloat().coerceIn(0f, 1f),
                    modifier = Modifier.fillMaxWidth()
                )
            }
            item.subtitle?.let {
                Text(
                    it,
                    style = LocalTypography.current.bodySmall,
                    color = LocalContentColors.current.secondary
                )
            }
        }
    }
}

@Composable
internal fun ActionHintBody(card: DashboardCard, interactive: Boolean) {
    // Subtitle and producer like every other template: iOS's action
    // summary shows the subtitle beside the value, and without this the
    // body is only ever the hint below.
    CardMetaLine(card)
    // An action card can still carry a chart: iOS detail draws it for any
    // template that has one, so this draws it rather than leaving the
    // hint as the whole body.
    val chart = card.chart?.takeIf { it.points.size >= 2 }
    if (chart != null) {
        val unknown = LocalContentColors.current.secondary
        val dark = isSystemInDarkTheme()
        val base = statusColor(card.status, unknown, dark)
        Spacer(Modifier.height(spacing.small))
        if (interactive) {
            InspectableChart(
                chart = chart,
                unit = card.unit,
                baseTint = base,
                modifier = Modifier.fillMaxWidth()
            )
        } else {
            Sparkline(
                chart = chart,
                baseTint = base,
                modifier = Modifier.fillMaxWidth().height(120.dp)
            )
        }
    }
}

@Composable
internal fun ChartBody(card: DashboardCard, interactive: Boolean) {
    CardMetaLine(card)
    val chart = card.chart ?: return
    Spacer(Modifier.height(spacing.small))
    // Base tint is the card's status tint, exactly like iOS (SparklineView
    // takes the card tint as its `tint` argument).
    val unknown = LocalContentColors.current.secondary
    val dark = isSystemInDarkTheme()
    val base = statusColor(card.status, unknown, dark)
    if (interactive) {
        InspectableChart(
            chart = chart,
            unit = card.unit,
            baseTint = base,
            modifier = Modifier.fillMaxWidth()
        )
    } else {
        Sparkline(
            chart = chart,
            baseTint = base,
            modifier = Modifier.fillMaxWidth().height(120.dp)
        )
    }
    chart.referenceMetadata?.label?.let { label ->
        Spacer(Modifier.height(spacing.xSmall))
        ReferenceLegend(chart = chart, baseTint = base, label = label)
    }
}

@Composable
internal fun HistoryBody(card: DashboardCard) {
    CardMetaLine(card)
    Spacer(Modifier.height(spacing.small))
    // Outcome pips, oldest first, most recent on the right (mirrors iOS).
    val unknown = LocalContentColors.current.secondary
    val dark = isSystemInDarkTheme()
    Row(horizontalArrangement = Arrangement.spacedBy(spacing.small)) {
        card.items.orEmpty().forEach { item ->
            Canvas(Modifier.size(14.dp)) { drawCircle(statusColor(item.status, unknown, dark)) }
        }
    }
    Spacer(Modifier.height(spacing.xSmall))
    card.items.orEmpty().takeLast(5).reversed().forEach { item ->
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(item.title, style = LocalTypography.current.body, modifier = Modifier.weight(1f))
            item.value?.let {
                Text(
                    it,
                    style = LocalTypography.current.bodySmall,
                    color = LocalContentColors.current.secondary
                )
            }
        }
    }
}

@Composable
internal fun BreakdownBody(card: DashboardCard) {
    CardMetaLine(card)
    Spacer(Modifier.height(spacing.small))
    val items = card.items.orEmpty()
    val total = items.sumOf { (it.amount ?: 0.0).coerceAtLeast(0.0) }.takeIf { it > 0 } ?: return
    val dark = isSystemInDarkTheme()
    // Segment colors for rows without a status: light pastels on dark
    // cards, saturated tones on light ones — neither reads on the other.
    val palette = if (dark) {
        listOf(
            Color(0xFF7DD3FC),
            Color(0xFFA5B4FC),
            Color(0xFF6EE7B7),
            Color(0xFFFCD34D),
            Color(0xFFF9A8D4)
        )
    } else {
        listOf(
            Color(0xFF007AFF),
            Color(0xFFAF52DE),
            Color(0xFF34C759),
            Color(0xFFFF9500),
            Color(0xFFFF3B30)
        )
    }
    Canvas(Modifier.fillMaxWidth().height(18.dp)) {
        var acc = 0.0
        val unknown = Color(0xFFB9C2CC)
        items.forEachIndexed { i, item ->
            val share = (item.amount ?: 0.0).coerceAtLeast(0.0) / total
            val left = (acc / total * size.width).toFloat()
            acc += (item.amount ?: 0.0).coerceAtLeast(0.0)
            val right = (acc / total * size.width).toFloat()
            val color = when (item.status) {
                DashboardStatus.UNKNOWN -> palette[i % palette.size]
                else -> statusColor(item.status, unknown, dark)
            }
            drawRect(color, Offset(left, 0f), Size(right - left, size.height))
        }
    }
    items.forEach { item ->
        Row(Modifier.fillMaxWidth()) {
            Text(item.title, style = LocalTypography.current.body, modifier = Modifier.weight(1f))
            item.value?.let {
                Text(
                    it,
                    style = LocalTypography.current.bodySmall,
                    color = LocalContentColors.current.secondary
                )
            }
        }
    }
}

@Composable
internal fun BriefingBody(card: DashboardCard) {
    CardMetaLine(card)
    Spacer(Modifier.height(spacing.xSmall))
    card.briefing?.sections.orEmpty().forEach { section ->
        section.label?.let {
            Text(
                it,
                style = LocalTypography.current.label,
                modifier = Modifier.padding(top = spacing.small)
            )
        }
        Text(section.text, style = LocalTypography.current.body)
    }
}

@Composable
internal fun TimelineBody(card: DashboardCard) {
    CardMetaLine(card)
    val timeline = card.timeline ?: return
    val unknown = LocalContentColors.current.secondary
    val dark = isSystemInDarkTheme()
    val base = statusColor(card.status, unknown, dark)
    Spacer(Modifier.height(spacing.xSmall))
    // Legend: series dot + label. FlowRow wraps long label sets onto
    // multiple lines instead of pushing the plot off the panel.
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(spacing.medium),
        verticalArrangement = Arrangement.spacedBy(spacing.xSmall)
    ) {
        timeline.series.take(4).forEachIndexed { index, series ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(spacing.xSmall)
            ) {
                Canvas(Modifier.size(7.dp)) {
                    drawCircle(chartTint(index, base, null, dark))
                }
                Text(
                    series.label,
                    style = LocalTypography.current.caption,
                    color = LocalContentColors.current.secondary,
                    maxLines = 1
                )
            }
        }
    }
    Spacer(Modifier.height(spacing.small))
    Row {
        if (timeline.lanes.size > 1) {
            Column(Modifier.width(72.dp)) {
                timeline.lanes.forEach { lane ->
                    Box(
                        Modifier.fillMaxWidth().weight(1f),
                        contentAlignment = Alignment.CenterEnd
                    ) {
                        Text(
                            lane.label,
                            style = LocalTypography.current.caption,
                            color = LocalContentColors.current.secondary,
                            maxLines = 1
                        )
                    }
                }
            }
            Spacer(Modifier.width(spacing.small))
        }
        TimelinePlot(
            timeline = timeline,
            baseTint = base,
            selectedFraction = null,
            modifier = Modifier.weight(1f).height(120.dp)
        )
    }
    Spacer(Modifier.height(spacing.xSmall))
    Row(Modifier.fillMaxWidth()) {
        Text(
            formatHourMinute(timeline.startAt),
            style = LocalTypography.current.caption,
            color = LocalContentColors.current.secondary
        )
        Spacer(Modifier.weight(1f))
        Text(
            formatHourMinute(timeline.endAt),
            style = LocalTypography.current.caption,
            color = LocalContentColors.current.secondary
        )
    }
}
