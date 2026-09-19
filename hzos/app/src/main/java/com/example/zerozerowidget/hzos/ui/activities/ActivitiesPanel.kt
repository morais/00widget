package com.example.zerozerowidget.hzos.ui.activities

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
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
import com.example.zerozerowidget.hzos.data.LiveActivitySession
import com.example.zerozerowidget.hzos.data.SampleData
import com.example.zerozerowidget.hzos.data.isSample
import com.example.zerozerowidget.hzos.ui.cards.Sparkline
import com.example.zerozerowidget.hzos.ui.cards.StatusDot
import com.example.zerozerowidget.hzos.ui.cards.activityTint
import com.example.zerozerowidget.hzos.ui.isStale
import com.example.zerozerowidget.hzos.ui.relativeTime

/**
 * Live Activities panel. Horizon OS has no ActivityKit equivalent, so
 * sessions render as live cards: state, headline value, progress, items,
 * countdown to endsAt. Same data as `GET /v1/live-activities`; polling keeps
 * it current while the panel is open.
 */
@Composable
fun ActivitiesPanel(app: ZeroZeroWidgetApp, onClose: () -> Unit, onOpenSettings: () -> Unit) {
    val state by app.repository.state.collectAsStateWithLifecycle()
    val samples by app.sampleStore.activities.collectAsState()
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.example.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )
    val visible = state.activities + samples

    Column(Modifier.fillMaxSize().padding(20.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Live Activities", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
            FilledTonalButton(onClick = onClose) { Text("Close") }
        }
        when {
            !state.isConfigured && samples.isEmpty() -> {
                Text("Not connected — set up the Connection panel first, or preview a demo activity.")
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = onOpenSettings) { Text("Open Connection") }
                    FilledTonalButton(
                        onClick = { app.sampleStore.generateActivity(SampleData.LiveActivitySample.APP_LAUNCH) },
                    ) { Text("Demo activity") }
                }
            }
            visible.isEmpty() -> {
                Text(
                    "No live activities running.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { app.repository.refresh() }) { Text("Refresh") }
                    FilledTonalButton(
                        onClick = { app.sampleStore.generateActivity(SampleData.LiveActivitySample.APP_LAUNCH) },
                    ) { Text("Demo activity") }
                }
            }
            else -> LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                items(visible, key = { it.externalActivityId }) { session ->
                    ActivityRow(session, cardAlpha)
                }
                item {
                    SampleActivityButtons(app)
                }
            }
        }
    }
}

/**
 * Both iOS demo sessions, mirroring LiveActivitySample. One runs at a
 * time (generating replaces), cleared with the cards via Clear samples.
 */
@Composable
private fun SampleActivityButtons(app: ZeroZeroWidgetApp) {
    Column {
        Spacer(Modifier.height(4.dp))
        Text(
            "Demo activities",
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(4.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SampleData.LiveActivitySample.entries.forEach { sample ->
                FilledTonalButton(
                    onClick = { app.sampleStore.generateActivity(sample) },
                ) { Text(sample.title) }
            }
        }
    }
}

@Composable
private fun ActivityRow(session: LiveActivitySession, cardAlpha: Float) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = cardAlpha),
            // Explicit: see DashboardRow — alpha breaks contentColorFor().
            contentColor = MaterialTheme.colorScheme.onSurface,
        ),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(14.dp)) {
            if (session.isSample()) {
                Text(
                    "SAMPLE",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
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
                    Text(session.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(session.state, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            session.subtitle?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            session.value?.let {
                Text(
                    it + (session.unit?.let { u -> " $u" } ?: ""),
                    style = MaterialTheme.typography.headlineSmall,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
            session.progress?.let {
                Spacer(Modifier.height(6.dp))
                LinearProgressIndicator(progress = { it.toFloat() }, modifier = Modifier.fillMaxWidth())
            }
            session.chart?.let {
                Spacer(Modifier.height(6.dp))
                Sparkline(
                    it,
                    activityTint(
                        session.kind,
                        session.signal,
                        MaterialTheme.colorScheme.primary,
                    ),
                    Modifier.fillMaxWidth().height(64.dp),
                )
            }
            session.items.orEmpty().take(4).forEach { item ->
                Row(Modifier.fillMaxWidth().padding(top = 2.dp)) {
                    Text(item.title, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
                    item.value?.let { v ->
                        Text(v, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            Row(Modifier.fillMaxWidth().padding(top = 6.dp)) {
                session.endsAt?.let { endsAt ->
                    Text(
                        "Ends ${relativeTime(endsAt) ?: endsAt}",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f),
                    )
                } ?: Spacer(Modifier.weight(1f))
                if (isStale(session.updatedAt, session.staleAt)) {
                    Text("stale", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
}
