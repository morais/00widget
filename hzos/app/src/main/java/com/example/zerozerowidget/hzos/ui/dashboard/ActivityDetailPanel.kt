package com.example.zerozerowidget.hzos.ui.dashboard

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.example.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.example.zerozerowidget.hzos.data.isSample
import com.example.zerozerowidget.hzos.ui.cards.InspectableChart
import com.example.zerozerowidget.hzos.ui.cards.StatusDot
import com.example.zerozerowidget.hzos.ui.cards.activityTint
import com.example.zerozerowidget.hzos.ui.isStale
import com.example.zerozerowidget.hzos.ui.relativeTime

/**
 * Full activity detail, hosted by CardDetailActivity alongside cards: every
 * item (not the dashboard's first four), the chart with hover inspection,
 * countdown, and link. One activity instance per popped-out activity, i.e.
 * one shell panel each — same pop-out story as cards.
 */
@Composable
fun ActivityDetailPanel(
    app: ZeroZeroWidgetApp,
    externalActivityId: String,
    onOpenLink: (String?) -> Unit,
) {
    val state by app.repository.state.collectAsStateWithLifecycle()
    val samples by app.sampleStore.activities.collectAsState()
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.example.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )
    val session = state.activities.firstOrNull { it.externalActivityId == externalActivityId }
        ?: samples.firstOrNull { it.externalActivityId == externalActivityId }

    Column(Modifier.fillMaxSize().padding(20.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                session?.title ?: "Activity",
                style = MaterialTheme.typography.headlineSmall,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            FilledTonalButton(onClick = { app.repository.refresh() }) { Text("Refresh") }
        }
        Spacer(Modifier.height(8.dp))
        if (session == null) {
            Text(
                "This activity has ended.",
                style = MaterialTheme.typography.bodyMedium,
            )
        } else {
            if (session.isSample()) {
                Text(
                    "SAMPLE · demo data",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.primary,
                )
                Spacer(Modifier.height(4.dp))
            }
            // Same glass container as widget details, so activity panels
            // read as the same object family rather than naked text.
            Card(
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = cardAlpha),
                    contentColor = MaterialTheme.colorScheme.onSurface,
                ),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                session.progress?.let {
                    Text(
                        "${(it * 100).toInt()}%",
                        style = MaterialTheme.typography.labelLarge,
                        modifier = Modifier.padding(end = 8.dp),
                    )
                } ?: StatusDot(
                    com.example.zerozerowidget.hzos.data.DashboardStatus.UNKNOWN,
                    Modifier.padding(end = 8.dp),
                )
                Column(Modifier.weight(1f)) {
                    Text(session.state, style = MaterialTheme.typography.titleSmall)
                    session.subtitle?.let {
                        Text(
                            it,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
            session.value?.let {
                Text(
                    it + (session.unit?.let { u -> " $u" } ?: ""),
                    style = MaterialTheme.typography.headlineMedium,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
            session.progress?.let {
                Spacer(Modifier.height(6.dp))
                LinearProgressIndicator(progress = { it.toFloat() }, modifier = Modifier.fillMaxWidth())
            }
            session.chart?.let { chart ->
                Spacer(Modifier.height(8.dp))
                InspectableChart(
                    chart = chart,
                    unit = session.unit,
                    baseTint = activityTint(
                        session.kind,
                        session.signal,
                        MaterialTheme.colorScheme.primary,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            session.items.orEmpty().forEach { item ->
                Row(Modifier.fillMaxWidth().padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    StatusDot(item.status, Modifier.padding(end = 6.dp))
                    Column(Modifier.weight(1f)) {
                        Text(item.title, style = MaterialTheme.typography.bodyMedium)
                        item.subtitle?.let {
                            Text(
                                it,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                    item.value?.let { v ->
                        Text(
                            v + (item.unit?.let { u -> " $u" } ?: ""),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                item.progress?.let { p ->
                    LinearProgressIndicator(
                        progress = { p.toFloat() },
                        modifier = Modifier.fillMaxWidth().padding(top = 2.dp),
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                session.endsAt?.let { endsAt ->
                    Text(
                        "Ends ${relativeTime(endsAt) ?: endsAt}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f),
                    )
                } ?: Spacer(Modifier.weight(1f))
                if (isStale(session.updatedAt, session.staleAt)) {
                    Text("stale", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.error)
                }
                session.deepLink?.let {
                    FilledTonalButton(onClick = { onOpenLink(session.deepLink) }) { Text("Open link") }
                }
            }
                }
            }
        }
    }
}
