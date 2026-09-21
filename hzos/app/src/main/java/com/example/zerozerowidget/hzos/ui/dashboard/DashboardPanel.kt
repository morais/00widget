package com.example.zerozerowidget.hzos.ui.dashboard

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.example.zerozerowidget.hzos.ZeroZeroWidgetApp
import com.example.zerozerowidget.hzos.data.DashboardCard
import com.example.zerozerowidget.hzos.data.LiveActivitySession
import com.example.zerozerowidget.hzos.data.SampleData
import com.example.zerozerowidget.hzos.data.isSample
import com.example.zerozerowidget.hzos.ui.cards.ActionButtons
import com.example.zerozerowidget.hzos.ui.cards.CardHeadline
import com.example.zerozerowidget.hzos.ui.cards.CardTemplateBody
import com.example.zerozerowidget.hzos.ui.cards.DeleteRow
import com.example.zerozerowidget.hzos.ui.cards.DetailCard
import com.example.zerozerowidget.hzos.ui.cards.PopOutIconButton
import com.example.zerozerowidget.hzos.ui.cards.SampleAwareDeleteRow
import com.example.zerozerowidget.hzos.ui.cards.SampleBadge
import com.example.zerozerowidget.hzos.ui.cards.SampleNoticeBanner
import com.example.zerozerowidget.hzos.ui.describeDeleteError
import com.example.zerozerowidget.hzos.ui.cards.Sparkline
import com.example.zerozerowidget.hzos.ui.cards.StatusDot
import com.example.zerozerowidget.hzos.ui.cards.activityTint
import com.example.zerozerowidget.hzos.ui.isStale
import com.example.zerozerowidget.hzos.ui.openDeepLink
import com.example.zerozerowidget.hzos.ui.relativeTime
import kotlinx.coroutines.launch

/**
 * Main dashboard panel, mirroring the Apple TV layout: an "Ongoing
 * Activities" section above the "Widgets" grid, one scroll. Tapping a card
 * expands it in place; "Pop out" opens it in its own shell panel (a
 * separate activity instance — pop out twice and you get two panels).
 */
@Composable
fun DashboardPanel(
    app: ZeroZeroWidgetApp,
    onOpenSettings: () -> Unit,
    onPopOut: (cardId: String) -> Unit,
    onPopOutActivity: (externalActivityId: String) -> Unit,
) {
    val context = LocalContext.current
    val state by app.repository.state.collectAsStateWithLifecycle()
    val samples by app.sampleStore.cards.collectAsState()
    val sampleActivities by app.sampleStore.activities.collectAsState()
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.example.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )
    var selectedId by remember { mutableStateOf<String?>(null) }
    var runningId by remember { mutableStateOf<String?>(null) }
    var runError by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    Column(Modifier.fillMaxSize().padding(20.dp)) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("Dashboard", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
            state.lastSyncEpochMs?.let {
                Text(
                    "synced ${relativeTime(java.time.Instant.ofEpochMilli(it).toString()) ?: ""}",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(end = 4.dp),
                )
            }
            IconButton(onClick = { app.repository.refresh() }) {
                Icon(Icons.Filled.Refresh, contentDescription = "Refresh")
            }
            IconButton(onClick = onOpenSettings) {
                Icon(Icons.Filled.Settings, contentDescription = "Settings")
            }
        }
        if (samples.isNotEmpty() || sampleActivities.isNotEmpty()) {
            SampleNoticeBanner(onRemoveAll = { app.sampleStore.clearSamples() })
            Spacer(Modifier.height(4.dp))
        }

        // Server cards first, local samples after — never mixed, never sent.
        val visible = state.cards + samples
        val visibleActivities = state.activities + sampleActivities
        val nothingToShow = visible.isEmpty() && visibleActivities.isEmpty()
        when {
            !state.isConfigured && nothingToShow -> {
                Text(
                    "Not connected. Sign in from the Connection panel — " +
                        "or explore with demo data, no account needed.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = onOpenSettings) { Text("Open Connection") }
                    FilledTonalButton(onClick = { app.sampleStore.generateCards() }) { Text("Generate samples") }
                }
            }
            state.error != null && nothingToShow -> {
                Text(state.error!!, color = MaterialTheme.colorScheme.error)
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { app.repository.refresh() }) { Text("Retry") }
                    FilledTonalButton(onClick = { app.sampleStore.generateCards() }) { Text("Generate samples") }
                }
            }
            nothingToShow -> {
                Text(
                    "No cards yet. Publish one from an agent, or explore with demo data.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                Spacer(Modifier.height(8.dp))
                Button(onClick = { app.sampleStore.generateCards() }) { Text("Generate samples") }
            }
            else -> {
                state.error?.let {
                    Text(it, color = MaterialTheme.colorScheme.error, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                val cardRow: @Composable (DashboardCard) -> Unit = { card ->
                    val isSample = card.isSample()
                    DashboardRow(
                        card = card,
                        cardAlpha = cardAlpha,
                        isSample = isSample,
                        expanded = selectedId == card.id,
                        onToggle = { selectedId = if (selectedId == card.id) null else card.id },
                        onPopOut = { onPopOut(card.id) },
                        onOpenLink = { openDeepLink(context, card.deepLink) },
                            actionSlot = {
                                // Sample cards are local demos: their buttons
                                // address nothing, so they don't run — but
                                // only say so when buttons exist at all.
                                if (isSample) {
                                    if (!card.actions.isNullOrEmpty()) {
                                        Text(
                                            "Demo card — buttons don't run on samples.",
                                            style = MaterialTheme.typography.bodySmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }
                                } else {
                                ActionButtons(
                                    card = card,
                                    runningId = runningId,
                                    runError = if (runningId != null) null else runError,
                                    onRun = { action ->
                                        scope.launch {
                                            runningId = action.id
                                            runError = null
                                            val result = app.repository.runAction(action.id, card.id)
                                            runningId = null
                                            runError = result.exceptionOrNull()?.message?.take(200)
                                        }
                                    },
                                )
                            }
                        },
                    )
                }
                // Width-driven columns, mirroring iOS DashboardView: one
                // column below 728dp, exactly two above — never three. iOS
                // counts a Duo hinge as a column boundary; Quest has no
                // hinge, so the width rule is the whole story. One scroll
                // for both sections: the grid is chunked into rows because
                // a lazy grid cannot live inside a lazy list.
                BoxWithConstraints(Modifier.fillMaxWidth().weight(1f)) {
                    val twoCol = maxWidth >= 728.dp
                    LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        if (visibleActivities.isNotEmpty()) {
                            item(key = "activities-title") {
                                SectionTitle("Ongoing Activities")
                            }
                            items(
                                visibleActivities,
                                key = { "act-" + it.externalActivityId },
                            ) { session ->
                                ActivityRow(
                                    session = session,
                                    cardAlpha = cardAlpha,
                                    onPopOut = { onPopOutActivity(session.externalActivityId) },
                                    onOpenDetail = { onPopOutActivity(session.externalActivityId) },
                                )
                            }
                        }
                        item(key = "widgets-title") {
                            SectionTitle("Widgets")
                        }
                        if (visible.isEmpty()) {
                            // No widgets: like the activities section, the
                            // Widgets section becomes its own demo picker.
                            item(key = "demo-widgets") {
                                FilledTonalButton(
                                    onClick = { app.sampleStore.generateCards() },
                                ) { Text("Generate samples") }
                            }
                        } else if (twoCol) {
                                items(
                                    visible.chunked(2),
                                    key = { row -> "row-" + row.first().id },
                                ) { row ->
                                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                        Box(Modifier.weight(1f)) { cardRow(row[0]) }
                                        if (row.size > 1) {
                                            Box(Modifier.weight(1f)) { cardRow(row[1]) }
                                        } else {
                                            Spacer(Modifier.weight(1f))
                                        }
                                    }
                                }
                            } else {
                                items(visible, key = { it.id }) { card -> cardRow(card) }
                            }
                    }
                }
            }
        }
    }
}

@Composable
private fun DashboardRow(
    card: DashboardCard,
    cardAlpha: Float,
    isSample: Boolean,
    expanded: Boolean,
    onToggle: () -> Unit,
    onPopOut: () -> Unit,
    onOpenLink: () -> Unit,
    actionSlot: @Composable () -> Unit,
) {
    // Overlay badge, not layout: the Box is exactly the card's size and the
    // pill draws over the bottom-right corner without moving anything.
    Box(Modifier.fillMaxWidth()) {
        Card(
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = cardAlpha),
                // Explicit: an alpha-modified container no longer matches any
                // theme color, so contentColorFor() can't derive this and text
                // falls back to ambient black. See ChartColors.kt note.
                contentColor = MaterialTheme.colorScheme.onSurface,
            ),
            modifier = Modifier.fillMaxWidth().clickable(onClick = onToggle),
        ) {
            Column(Modifier.padding(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CardHeadline(card, Modifier.weight(1f))
                PopOutIconButton(onPopOut)
            }
            card.subtitle?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (isStale(card.updatedAt, card.staleAfter)) {
                Text("stale", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.error)
            }
            if (expanded) {
                Spacer(Modifier.height(8.dp))
                CardTemplateBody(card)
                actionSlot()
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    card.deepLink?.let {
                        FilledTonalButton(onClick = onOpenLink) { Text("Open link") }
                    }
                }
            }
        }
        }
        if (isSample) {
            SampleBadge(
                Modifier
                    .align(Alignment.BottomEnd)
                    .padding(8.dp),
            )
        }
    }
}

/**
 * Single-card detail surface, hosted by CardDetailActivity — one activity
 * instance per popped-out card, i.e. one shell panel per card.
 */
@Composable
fun CardDetailPanel(
    app: ZeroZeroWidgetApp,
    cardId: String,
    onOpenLink: (String?) -> Unit,
    onDeleted: () -> Unit,
) {
    val state by app.repository.state.collectAsStateWithLifecycle()
    val samples by app.sampleStore.cards.collectAsState()
    val cardAlpha by app.panelPrefs.cardAlpha.collectAsState(
        initial = com.example.zerozerowidget.hzos.ui.PanelPrefs.DEFAULT_CARD_ALPHA,
    )
    var runningId by remember { mutableStateOf<String?>(null) }
    var runError by remember { mutableStateOf<String?>(null) }
    var deleting by remember { mutableStateOf(false) }
    var deleteError by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val card = state.cards.firstOrNull { it.id == cardId }
        ?: samples.firstOrNull { it.id == cardId }
    val isSample = card?.isSample() == true

    // Shell panels have one fixed window height each; tall content (long
    // briefings, full item lists, inspection panels) scrolls inside it.
    // The OS cannot size a panel to its content, so scroll is the whole
    // answer — sizing the window to content is not an API that exists.
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                card?.title ?: "Card",
                style = MaterialTheme.typography.headlineSmall,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            IconButton(onClick = { app.repository.refresh() }) {
                Icon(Icons.Filled.Refresh, contentDescription = "Refresh")
            }
        }
        Spacer(Modifier.height(8.dp))
        if (card == null) {
            Text(
                "This card is no longer on the dashboard.",
                style = MaterialTheme.typography.bodyMedium,
            )
        } else {
            if (isSample) {
                SampleBadge()
                Spacer(Modifier.height(4.dp))
            }
            DetailCard(card, cardAlpha, interactiveCharts = true)
            Spacer(Modifier.height(10.dp))
            if (isSample) {
                if (!card.actions.isNullOrEmpty()) {
                    Text(
                        "Demo card — buttons don't run on samples.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                ActionButtons(
                    card = card,
                    runningId = runningId,
                    runError = runError,
                    onRun = { action ->
                        scope.launch {
                            runningId = action.id
                            runError = null
                            val result = app.repository.runAction(action.id, card.id)
                            runningId = null
                            runError = result.exceptionOrNull()?.message?.take(200)
                        }
                    },
                )
            }
            Spacer(Modifier.height(8.dp))
            card.deepLink?.let {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilledTonalButton(onClick = { onOpenLink(card.deepLink) }) { Text("Open link") }
                }
                Spacer(Modifier.height(8.dp))
            }
            SampleAwareDeleteRow(
                isSample = isSample,
                serverLabel = "Delete",
                busy = deleting,
                error = deleteError,
                onDelete = {
                    scope.launch {
                        deleting = true
                        deleteError = null
                        val ok = if (isSample) {
                            app.sampleStore.removeCard(cardId)
                            true
                        } else {
                            val result = app.repository.deleteCard(cardId)
                            deleteError = result.exceptionOrNull()?.let(::describeDeleteError)
                            result.isSuccess
                        }
                        deleting = false
                        if (ok) onDeleted()
                    }
                },
            )
            card.deadline?.let { deadline ->
                Spacer(Modifier.height(6.dp))
                Text(
                    "Due ${relativeTime(deadline) ?: deadline}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.onSurface,
    )
}

@Composable
private fun ActivityRow(session: LiveActivitySession, cardAlpha: Float, onPopOut: () -> Unit, onOpenDetail: () -> Unit) {
    // Overlay badge, not layout — see DashboardRow.
    Box(Modifier.fillMaxWidth()) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = cardAlpha),
            // Explicit: see DashboardRow — alpha breaks contentColorFor().
            contentColor = MaterialTheme.colorScheme.onSurface,
        ),
        modifier = Modifier.fillMaxWidth().clickable(onClick = onOpenDetail),
    ) {
        Column(Modifier.padding(14.dp)) {
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
                PopOutIconButton(onPopOut)
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
        if (session.isSample()) {
            SampleBadge(
                Modifier
                    .align(Alignment.BottomEnd)
                    .padding(8.dp),
            )
        }
    }
}
